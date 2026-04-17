---
name: video-edit
description: Edit video files — trim, concatenate, ramp slow-mo, re-encode, change resolution, extract audio, mix music, add subtitles/text, convert formats — via ffmpeg. Use when the user asks to edit, cut, combine, compress, convert, or transform a video.
---

# Video Edit Skill

Wraps **ffmpeg**. Assume it's installed (`brew install ffmpeg` on macOS); if not, tell the user and stop. Assume your model can see images — frame extraction + vision is the primary verification path, not an afterthought.

## Core principle: prefer stream copying over re-encoding

Re-encoding is slow and lossy. Ask: do I need to re-encode, or can I just copy the streams?

- **Trim / cut / concatenate same-format clips**: stream copy with `-c copy`. Instant, no quality loss.
- **Change resolution, compress, change codec, apply filters**: must re-encode.
- **Container change only (`.mov` → `.mp4`)**: stream copy, usually works.

## Verification: see, don't just inspect

Every edit ends with a visual check. Metadata alone is insufficient — `ffprobe` proves the file parses, not that the edit is correct.

### 1. Scene / timestamp detection (when you need to locate an action)

You don't need the user to time everything manually. Extract frames at regular intervals, then look at them to find the moment the action happens.

```bash
# Every 1 second, write frame_001.jpg, frame_002.jpg, ...
ffmpeg -i input.mp4 -vf fps=1 -q:v 2 /tmp/frames/frame_%03d.jpg
```

Then `read_file` the frames in order, identify which one shows the action you're looking for, compute its timestamp (frame N at `fps=1` is at second N-1). Tighten the sampling rate (`fps=5` = every 200ms) when you need sub-second precision. This replaces guessing at timestamps.

### 2. Post-edit QA

After producing the output, sample frames across the result and read_file each. Not just "the middle frame." Confirm:

- Intended edits are visible (slow-mo segment played back long, text overlay appears at expected times, logo stays in the corner, etc.)
- No clipped content, no frozen frames, no black segments
- Visual continuity across cuts

```bash
# Sample 6 frames evenly across the output
ffmpeg -i output.mp4 -vf "select='not(mod(n,floor(total_frames/6)))',setpts=N/FRAME_RATE/TB" -vsync vfr -q:v 2 /tmp/qa/frame_%02d.jpg
# Simpler alternative: explicit timestamps
for t in 00:00:01 00:00:10 00:00:20 00:00:30 00:00:45 00:00:59; do
  ffmpeg -ss "$t" -i output.mp4 -vframes 1 -q:v 2 "/tmp/qa/qa_${t//:/-}.jpg"
done
```

### 3. Metadata sanity (via ffprobe)

Use for things vision can't answer: duration, codecs, stream count, resolution, bitrate.

```bash
ffprobe -v error -show_format -show_streams -of json output.mp4
```

### Stopping criterion

Cap at 3 visual QA iterations. If the output is still wrong after 3 render-inspect-fix rounds, stop and describe what's wrong to the user — don't burn budget on subjective polish.

## Cuts & joins

### Trim a segment (stream copy, fast)
```bash
ffmpeg -i input.mp4 -ss 00:01:30 -to 00:02:45 -c copy output.mp4
```
Stream-copied trims snap to the nearest keyframe (may start a second or two early/late). For frame-accurate cuts, drop `-c copy` to force re-encoding.

### Concatenate clips of the same format
```bash
# Create list.txt: file 'clip1.mp4'\nfile 'clip2.mp4'
ffmpeg -f concat -safe 0 -i list.txt -c copy output.mp4
```
If formats differ, re-encode the inputs to matching codec + resolution + framerate first.

### Transition between two clips (crossfade / dissolve)
```bash
# 1-second fade starting at offset 4s of the first clip
ffmpeg -i clip1.mp4 -i clip2.mp4 -filter_complex \
  "[0:v][1:v]xfade=transition=fade:duration=1:offset=4[v]; [0:a][1:a]acrossfade=d=1[a]" \
  -map "[v]" -map "[a]" output.mp4
```
`offset` = `clip1_duration - transition_duration`. Transitions: `fade`, `dissolve`, `wipeleft/right`, `slideleft/right`, `circleopen/close`, `radial`. Clips must match resolution + framerate.

## Speed & time

### Change speed (simple, whole clip)
```bash
# Slow 2x (half speed)
ffmpeg -i input.mp4 -filter_complex "[0:v]setpts=2.0*PTS[v]; [0:a]atempo=0.5[a]" -map "[v]" -map "[a]" output.mp4

# Speed up 2x
ffmpeg -i input.mp4 -filter_complex "[0:v]setpts=0.5*PTS[v]; [0:a]atempo=2.0[a]" -map "[v]" -map "[a]" output.mp4
```
`atempo` is clamped to 0.5–2.0 — chain for more: `atempo=2.0,atempo=2.0`. Drop audio entirely with `-an` instead of `[0:a]atempo...`.

### Selective slow-motion (ramping)

Slow down ONE segment while keeping the rest at normal speed. Common for dives, jumps, sports plays. The pattern: trim into segments, slow the target segment, reset each segment's timestamps with `setpts=PTS-STARTPTS`, concat back.

```bash
# Input is 10s. Slow seconds 4-5 by 4x. Keep rest at normal speed.
ffmpeg -i input.mp4 -filter_complex \
  "[0:v]trim=0:4,setpts=PTS-STARTPTS[v1]; \
   [0:v]trim=4:5,setpts=4.0*(PTS-STARTPTS)[v2]; \
   [0:v]trim=5:10,setpts=PTS-STARTPTS[v3]; \
   [v1][v2][v3]concat=n=3:v=1:a=0[vout]; \
   [0:a]atrim=0:4,asetpts=PTS-STARTPTS[a1]; \
   [0:a]atrim=4:5,atempo=0.5,atempo=0.5,asetpts=PTS-STARTPTS[a2]; \
   [0:a]atrim=5:10,asetpts=PTS-STARTPTS[a3]; \
   [a1][a2][a3]concat=n=3:v=0:a=1[aout]" \
  -map "[vout]" -map "[aout]" -c:v libx264 -pix_fmt yuv420p output.mp4
```

Key rules:
- `setpts=PTS-STARTPTS` **mandatory** after every `trim` — skipping it causes duration corruption and frozen frames.
- `asetpts=PTS-STARTPTS` is the audio equivalent for `atrim`.
- Video `setpts` multiplier vs audio `atempo`: to slow 4x, video uses `4.0*PTS` and audio uses `atempo=0.5,atempo=0.5` (chained because atempo's range is 0.5–2.0).
- Always include `-pix_fmt yuv420p` in ramping output — hardware decoders on web/mobile/TVs expect it.

Use the scene-detection workflow above to find the segment timestamps visually; don't guess.

### Reverse playback
```bash
ffmpeg -i input.mp4 -vf reverse -af areverse output.mp4
```
Buffers the whole stream in RAM. For clips over ~10 minutes HD, split first, reverse each piece, concatenate in reverse order.

## Transform

### Compress / reduce file size
```bash
ffmpeg -i input.mp4 -vcodec libx264 -crf 23 -preset medium -pix_fmt yuv420p -acodec aac -b:a 128k output.mp4
```
CRF: 18 = visually lossless, 23 = default, 28 = aggressive. +2 CRF ≈ half the output size.

### Resize (e.g., 1080p → 720p)
```bash
ffmpeg -i input.mp4 -vf scale=-2:720 -pix_fmt yuv420p -c:a copy output.mp4
```
`-2` preserves aspect ratio and keeps the width even (required by most codecs).

### Crop
```bash
ffmpeg -i input.mp4 -vf "crop=1280:720:0:0" -c:a copy output.mp4
```
`crop=w:h:x:y`. To chop 100px off left and right: `crop=in_w-200:in_h:100:0`.

### Rotate / flip
```bash
ffmpeg -i input.mp4 -vf "transpose=1" -c:a copy output.mp4   # 90° CW
ffmpeg -i input.mp4 -vf "transpose=2" -c:a copy output.mp4   # 90° CCW
ffmpeg -i input.mp4 -vf "hflip" -c:a copy output.mp4         # mirror
ffmpeg -i input.mp4 -vf "transpose=1,transpose=1" output.mp4 # 180°
```

## Audio

### Extract audio
```bash
ffmpeg -i input.mp4 -vn -acodec copy output.aac
ffmpeg -i input.mp4 -vn -acodec libmp3lame -b:a 192k output.mp3
```

### Replace audio track (mute original, use new)
```bash
ffmpeg -i video.mp4 -i new_audio.mp3 -c:v copy -map 0:v:0 -map 1:a:0 -shortest output.mp4
```

### Add music to silent video — same command as replace.

### Mix original + background music
```bash
ffmpeg -i video.mp4 -i music.mp3 \
  -filter_complex "[0:a]volume=1.0[v]; [1:a]volume=0.25[m]; [v][m]amix=inputs=2:duration=first[a]" \
  -map 0:v -map "[a]" -c:v copy -c:a aac -b:a 192k output.mp4
```
Music at 0.15–0.35 keeps narration/dialog dominant.

### Fade music in/out
```bash
ffmpeg -i video.mp4 -i music.mp3 \
  -filter_complex "[1:a]afade=t=in:st=0:d=2,afade=t=out:st=58:d=2,volume=0.3[m]; [0:a][m]amix=inputs=2:duration=first[a]" \
  -map 0:v -map "[a]" -c:v copy -c:a aac output.mp4
```
Set fade-out `st` to `video_duration - 2`. Read duration via ffprobe.

### Start music at a specific moment (adelay)
Use when music should kick in at an event (e.g., a splash) rather than at t=0.
```bash
# Delay music by 4.5 seconds (4500 ms)
ffmpeg -i video.mp4 -i music.mp3 \
  -filter_complex "[1:a]adelay=4500|4500[m]; [0:a][m]amix=inputs=2:duration=first[a]" \
  -map 0:v -map "[a]" -c:v copy -c:a aac output.mp4
```
`adelay=N|N` applies delay in ms to both stereo channels. Use the scene-detection workflow to find the trigger timestamp visually.

### Loop music to match a longer video
```bash
ffmpeg -stream_loop -1 -i music.mp3 -i video.mp4 \
  -filter_complex "[0:a]volume=0.3[m]; [1:a][m]amix=inputs=2:duration=first[a]" \
  -map 1:v -map "[a]" -c:v copy -c:a aac -shortest output.mp4
```

### Trim music to a specific length before mixing
```bash
ffmpeg -i music.mp3 -t 60 -c copy music_60s.mp3
```

### Mute a specific segment (silence between t1 and t2)
```bash
ffmpeg -i input.mp4 -af "volume=0:enable='between(t,10,15)'" -c:v copy output.mp4
```

## Overlays

### Text on screen (titles, captions, watermarks)
```bash
ffmpeg -i input.mp4 -vf \
  "drawtext=fontfile=/System/Library/Fonts/Supplemental/Arial.ttf:text='Hello world':fontcolor=white:fontsize=48:x=(w-text_w)/2:y=h-100:box=1:boxcolor=black@0.5:boxborderw=10" \
  -c:a copy output.mp4
```
Time-gate with `:enable='between(t,3,6)'` to show between 3s–6s. Different from burned subtitles — this is for titles, credits, on-screen labels.

For positioning over a subject, use scene detection to see where the subject is in frame, then place text accordingly.

### Burn subtitles into the video (hard subs)
```bash
ffmpeg -i input.mp4 -vf "subtitles=subs.srt" -c:a copy output.mp4
```
For soft subs (toggleable), use `-c:s mov_text` and add `.srt` as an input stream.

### Picture-in-picture / logo watermark
```bash
# Logo PNG in top-right with 10px padding
ffmpeg -i main.mp4 -i logo.png -filter_complex "[0:v][1:v]overlay=W-w-10:10" -c:a copy output.mp4

# Webcam in bottom-right, scaled to 25% of main width
ffmpeg -i screen.mp4 -i webcam.mp4 -filter_complex \
  "[1:v]scale=iw*0.25:-1[pip]; [0:v][pip]overlay=W-w-20:H-h-20" -c:a copy output.mp4
```
`W,H` = main dimensions; `w,h` = overlay. Corners: `0:0`, `W-w:0`, `0:H-h`, `W-w:H-h`.

## Special

### GIF (with decent colors — two-pass palette)
```bash
ffmpeg -i input.mp4 -vf "fps=12,scale=480:-2:flags=lanczos,palettegen" -t 10 /tmp/palette.png
ffmpeg -i input.mp4 -i /tmp/palette.png -filter_complex "fps=12,scale=480:-2:flags=lanczos[x];[x][1:v]paletteuse" -t 10 output.gif
```
12fps × 480px wide is a good default. Keep GIFs under ~15s.

### Extract a single frame as image
```bash
ffmpeg -i input.mp4 -ss 00:00:30 -vframes 1 -q:v 2 thumbnail.jpg
```

## Common pitfalls

- **Missing `setpts=PTS-STARTPTS` after trim** → duration corruption, frozen frames, duplicated timestamps. **Mandatory** inside filter_complex whenever you use `trim` or `atrim`.
- **Missing `-pix_fmt yuv420p`** → file plays in VLC but not on phones/TVs/web players. Include it on every re-encode targeting distribution.
- **`atempo` out of range** → chain filters: `atempo=2.0,atempo=2.0` for 4x, `atempo=0.5,atempo=0.5` for 0.25x.
- **"Odd width" encoding error** → h264 needs even pixel dimensions. Use `scale=-2:720` (even) not `scale=-1:720` (any).
- **Audio out of sync after concat** → inputs had different framerates. Re-encode all to the same rate first: `-r 30`.
- **Audio out of sync after slow-mo** → forgot to slow audio OR forgot `asetpts=PTS-STARTPTS` after `atrim`.
- **Music too loud, drowns dialog** → music volume should be 0.15–0.35 when original audio is kept at 1.0.
- **Mix output shorter than video** → music ran out; add `duration=first` to `amix` or loop music with `-stream_loop -1`.
- **No audio in output after `-map`** → you mapped video-only and forgot audio. Pair `-map 0:v` with `-map 0:a` (or `-map "[a]"` for filter-graph output).
- **GIF looks washed out / posterized** → skipped the two-pass palette. Always palettegen → paletteuse for quality.
- **`xfade` fails on "identical format"** → clips differ in resolution/pixel format/framerate. Normalize both first: `-vf scale=W:H,fps=30 -pix_fmt yuv420p`.
- **`drawtext` "Cannot load fontfile"** → wrong path or missing permissions. Reliable macOS paths: `/System/Library/Fonts/Supplemental/Arial.ttf`, `/System/Library/Fonts/Helvetica.ttc`.
- **Reverse filter OOM** → splits the stream, process chunks.
- **`-ss` before vs after `-i`** → before = fast but snaps to keyframe; after = slow but frame-accurate. Use after when re-encoding anyway.

## What this skill doesn't do

Complex timelines with graphic transitions, color grading, stabilization, denoising, chroma key — use a real NLE (Final Cut, DaVinci Resolve). ffmpeg's filters exist for these but produce worse results than a proper tool.
