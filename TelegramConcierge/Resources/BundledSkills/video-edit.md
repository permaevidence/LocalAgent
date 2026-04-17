---
name: video-edit
description: Edit video files — trim, concatenate, re-encode, change resolution, extract audio, add subtitles, convert formats — via ffmpeg. Use when the user asks to edit, cut, combine, compress, or convert a video.
---

# Video Edit Skill

This skill wraps **ffmpeg** — the universal video processing tool. Assume it's installed (`brew install ffmpeg` on macOS); if not, tell the user and stop.

## Core principle: prefer stream copying over re-encoding

Re-encoding is slow and lossy. Always ask: do I need to re-encode, or can I just copy the streams?

- **Trim / cut / concatenate same-format clips**: stream copy with `-c copy`. Instant, no quality loss.
- **Change resolution, compress, change codec**: must re-encode. Slow (roughly realtime to 3x speed for modern codecs).
- **Format container change only (`.mov` → `.mp4`)**: stream copy, usually works.

## Common operations

### Trim a segment (stream copy, fast)
```bash
ffmpeg -i input.mp4 -ss 00:01:30 -to 00:02:45 -c copy output.mp4
```
**Gotcha**: stream-copied trims snap to the nearest keyframe, so the cut may start a second or two early/late. For frame-accurate cuts, re-encode by removing `-c copy`.

### Concatenate clips of the same format
```bash
# Create list.txt with: file 'clip1.mp4'\nfile 'clip2.mp4'
ffmpeg -f concat -safe 0 -i list.txt -c copy output.mp4
```
If formats differ, re-encode the inputs first to match codec + resolution + framerate, then concat.

### Compress / reduce file size
```bash
ffmpeg -i input.mp4 -vcodec libx264 -crf 23 -preset medium -acodec aac -b:a 128k output.mp4
```
CRF controls quality vs size. 18 = visually lossless, 23 = default, 28 = aggressive compression. Raise CRF by 2 to roughly halve the output.

### Resize (e.g., 1080p → 720p)
```bash
ffmpeg -i input.mp4 -vf scale=-2:720 -c:a copy output.mp4
```
`-2` preserves aspect ratio and keeps even width (required by most codecs).

### Extract audio
```bash
ffmpeg -i input.mp4 -vn -acodec copy output.aac
# or to mp3:
ffmpeg -i input.mp4 -vn -acodec libmp3lame -b:a 192k output.mp3
```

### Replace the audio track entirely (mute original, use a new track)
```bash
ffmpeg -i video.mp4 -i new_audio.mp3 -c:v copy -map 0:v:0 -map 1:a:0 -shortest output.mp4
```
`-shortest` stops output when either stream ends. Use `-c:a aac -b:a 192k` instead of copying if the replacement audio is in a container-incompatible codec.

### Add music to a silent video
Same command as above — works whether the original had no audio track or you're muting it.

### Mix original audio + background music (both audible)
```bash
ffmpeg -i video.mp4 -i music.mp3 \
  -filter_complex "[0:a]volume=1.0[v]; [1:a]volume=0.25[m]; [v][m]amix=inputs=2:duration=first[a]" \
  -map 0:v -map "[a]" -c:v copy -c:a aac -b:a 192k output.mp4
```
`volume=0.25` drops the music to 25% so narration / dialog stays dominant. Tune 0.15–0.35 to taste. `duration=first` makes the mix as long as the original video (music is trimmed or silence-padded).

### Add music with fade in / fade out
```bash
ffmpeg -i video.mp4 -i music.mp3 \
  -filter_complex "[1:a]afade=t=in:st=0:d=2,afade=t=out:st=58:d=2,volume=0.3[m]; [0:a][m]amix=inputs=2:duration=first[a]" \
  -map 0:v -map "[a]" -c:v copy -c:a aac output.mp4
```
`afade=t=in:st=0:d=2` = fade in over 2s from the start. `st=58:d=2` = fade out for 2s starting at 58s (tune to `video_duration - 2`). Get the video duration first via `ffprobe`.

### Loop music to match a longer video
```bash
ffmpeg -stream_loop -1 -i music.mp3 -i video.mp4 \
  -filter_complex "[0:a]volume=0.3[m]; [1:a][m]amix=inputs=2:duration=first[a]" \
  -map 1:v -map "[a]" -c:v copy -c:a aac -shortest output.mp4
```
`-stream_loop -1` loops the music infinitely; `-shortest` stops at the video's end. Order of inputs flipped: music is `0`, video is `1` — required for `-stream_loop` to apply.

### Trim music to a specific length before mixing
```bash
ffmpeg -i music.mp3 -t 60 -c copy music_60s.mp3
```
Then mix as usual. Useful when you want precise control over a song's start/end.

### Burn subtitles into the video (hard subs)
```bash
ffmpeg -i input.mp4 -vf "subtitles=subs.srt" -c:a copy output.mp4
```
For soft subs (toggleable), use `-c:s mov_text` and add `.srt` as an input.

### Extract a single frame as image
```bash
ffmpeg -i input.mp4 -ss 00:00:30 -vframes 1 -q:v 2 thumbnail.jpg
```

## Verification loop

Videos can't be played inside the agent's context. Verify programmatically:

1. **`ffprobe` the output.** Check duration, resolution, codecs match expectation.
   ```bash
   ffprobe -v error -show_format -show_streams -of json output.mp4
   ```
2. **Extract a representative frame** (e.g., middle of video) as an image and `read_file` that — confirms the video isn't black or corrupted.
3. **Check file size** sanity (`ls -la`). 10 MB for a 1-hour 1080p compressed video = probably broken.

Cap at 3 iterations. If the user reports a visual problem that the agent can't detect through ffprobe + sampled frames, stop and ask the user to spot-check.

## What to verify

- Duration is what the user asked for (`ffprobe` → `format.duration`)
- Resolution is correct (`streams[].width`/`height`)
- Audio stream is present if expected (check `streams[].codec_type == "audio"`)
- Output file is substantially smaller than input when compressing, not 1:1 (would mean re-encode didn't actually compress)

## Common bugs

- **"Odd width" encoding error**: h264 requires even pixel dimensions. Use `scale=-2:720` (even) not `scale=-1:720` (any).
- **Audio out of sync after concat**: inputs had different framerates. Re-encode all to the same rate first: `-r 30`.
- **Music too loud, drowns dialog**: when mixing, the original audio should stay at `volume=1.0` and music should be `0.15–0.35`. Above 0.5, music dominates.
- **Mix output shorter than video**: music ran out. Add `duration=first` to `amix` or loop the music with `-stream_loop -1`.
- **No audio in output after `-map`**: you mapped video-only (`-map 0:v`) and forgot to map the audio stream. Always pair `-map video_spec` with `-map audio_spec` (or `-map "[a]"` for a filter graph output).
- **`-ss` before `-i` vs after**: `-ss` BEFORE `-i` is fast but less accurate; AFTER `-i` is slow but frame-accurate. Use before for stream-copy trims, after when re-encoding anyway.
- **Subtitles not showing**: `subtitles=` filter needs the file in a readable path. Absolute paths help. Special characters in filenames break it — escape or rename.
- **Massive output file**: check you're not accidentally copying an uncompressed raw stream. Specify `-c:v libx264` explicitly.

## What this skill doesn't do

- Complex editing timelines with transitions, titles, color grading → use a real NLE (Final Cut, Premiere, DaVinci Resolve). Ffmpeg is for mechanical operations.
- Green screen / chroma key → technically possible via `colorkey` filter, but fragile. Recommend a video editor.
- Real-time streaming setup → outside scope; tell the user.

## Stopping criterion

`ffprobe` confirms the output matches spec (duration, resolution, codecs, streams), sampled frames look reasonable, file size is in the expected range. Ship it.
