# LocalAgent Architecture Plan

Forked from ConciergeForTelegram on 2026-04-13. Diverging into a filesystem-native autonomous coding agent for multimodal local models (Gemma 4, Qwen VL class). This document is the durable specification — it survives context compaction and is the first file a new session should read.

## Philosophy

- **Agent is the primary user of the computer.** The human interacts only via Telegram and never sees or thinks about paths.
- **No sandbox.** The agent operates on the whole filesystem, via absolute paths.
- **Full autonomy.** No permission prompts, no approval diffs, no write guardrails. Targeted for autonomous remote operation over Telegram.
- **Multimodal-first.** Target models are multimodal (Gemma 4, Qwen VL). No OCR fallbacks. Images and PDFs are shown to the model as visual content.
- **Memory over filesystem.** Discovery is driven by a breadcrumb ledger the agent maintains, not by cwd or by walking the disk. The chat history (with absolute paths embedded in breadcrumbs) is the agent's filesystem memory.
- **Delegation for heavy coding.** Complex multi-file refactors still route through Claude Code / Codex / Gemini CLI via the existing `run_claude_code` tool family. The new filesystem tools are for the agent's own direct operations.

## Tool surface

Net change from parent project: −6 removed, +11 added (+5 net).

### Removed (6)

- `list_documents`
- `read_document`
- `browse_project`
- `read_project_file`
- `add_project_files`
- `generate_document`

### Added (11)

1. **`read_file(path, offset?, limit?=2000)`** — absolute paths only. Text: 2000 lines / 50 KB / 2000-char-per-line caps. For image or PDF mimetypes, stash the bytes and inject as a synthetic user message on the next turn labeled `Attached from read_file: <path>` (rationale below). Updates FileTime snapshot.
2. **`write_file(path, content)`** — create or overwrite. If the file exists, requires a prior read_file in this session; asserts FileTime (mtime, size) unchanged. Hard-errors on staleness with both timestamps. Creates parent directories. Records to ledger with `origin: "edited"` (or `"generated"` for new files).
3. **`edit_file(path, old_string, new_string, replace_all?=false)`** — surgical find/replace. Unique match required unless `replace_all=true`. FileTime check. 3-strategy fallback: literal → line-trimmed → whitespace-normalized. Strict errors ("must match exactly including whitespace", "found N matches — provide more context").
4. **`apply_patch(patch_text)`** — Codex envelope: `*** Begin Patch` / `*** Update File: <path>` / `*** Add File: <path>` / `*** Delete File: <path>` / `*** Move to: <path>` / `@@` anchors / `+` `-` ` ` line prefixes / `*** End Patch`. Atomic: parse all hunks across all files first, then apply all; roll back if any hunk fails. Multi-file in one call. Kept alongside `edit_file` because local models sometimes prefer one format over the other.
5. **`grep(pattern, path?, include?, max_results?=100)`** — ripgrep-backed content search. 100-match cap, 2000-char-per-line cap, sorted by mtime descending.
6. **`glob(pattern, path?)`** — filename-pattern search. 100-file cap, sorted by mtime.
7. **`list_dir(path, ignore?)`** — tree view of a directory. 100-entry cap. Baked-in ignores: `.git/`, `node_modules/`, `__pycache__/`, `.venv/`, `dist/`, `.DS_Store`, `.next/`, `.build/`, `.swiftpm/`, `DerivedData/`.
8. **`list_recent_files(limit?=20, offset?=0, filter_origin?)`** — memory-backed: reads `files_ledger.json`, NOT the disk. Returns recently-touched files across the whole filesystem, sorted by `last_touched` descending, with descriptions. Filter by origin.
9. **`bash(command, timeout_ms?=120000, workdir?, description, run_in_background?=false)`** — shell execution. 600 s hard max timeout, 30 KB output cap, `~` and `$VAR` expansion. When `run_in_background=true`, spawns and returns immediately with a handle like `bash_1`.
10. **`bash_output(handle, since?=0)`** — read accumulated stdout/stderr for a background process. Returns text + status (running/exited) + exit_code if done.
11. **`bash_kill(handle)`** — SIGTERM then SIGKILL after grace period.

## Paths: absolute only

Every tool parameter that names a file takes an absolute path. No cwd. No relative paths. Matches Claude Code's convention and avoids a class of "where am I?" bugs with local models.

## FileTime subsystem

Swift actor keyed by absolute path. On each successful `read_file`, snapshot `{mtime, size, readAt}`. On each `write_file` / `edit_file` / `apply_patch` update, assert the current on-disk (mtime, size) matches the snapshot. If not, hard-error with both timestamps and message: "File changed since last read. Re-read before modifying."

The FileTime lives in memory for the session (not persisted) — it's protection against in-session staleness, not cross-session.

## Files ledger

JSON file at `~/Library/Application Support/LocalAgent/files_ledger.json`. Schema per entry:

```json
{
  "path": "/Users/alice/Desktop/foo/bar.swift",
  "description": "Swift service handling X",
  "last_touched": "2026-04-13T18:45:00-04:00",
  "origin": "edited|generated|telegram|email|download",
  "touch_count": 3
}
```

**Only writes update the ledger** (decision 2026-04-13). Reads do not bloat it. This keeps the ledger focused on "what the agent has modified or received." Writes include: `write_file`, `edit_file`, `apply_patch`, incoming Telegram attachment saved to landing zone, email attachment download, URL download, file sent to chat (sends don't write but are user-initiated and worth tracking — TBD during implementation).

`list_recent_files` reads the ledger and returns entries sorted by `last_touched` descending.

## Landing zone

`~/Documents/LocalAgent/` with subfolders:

- `telegram/` — incoming Telegram attachments
- `email/` — email attachment downloads
- `downloads/` — URL downloads
- `generated/` — image-gen and document output

Auto-created on first launch. Files land here by default but the agent can move them anywhere via `bash` or `write_file`.

## Multimodal routing for images/PDFs

OpenAI-compatible endpoints (the only kind LocalAgent targets) do not accept image content blocks inside tool_result. Even when Gemma 4 / Qwen VL *can* see images, the inference stack (llama.cpp, vLLM, Ollama) passes tool results through as text.

Workaround: when `read_file` is called on an image or PDF, the tool returns a short text acknowledgment AND the harness stashes the image bytes. On the next turn's payload construction, a synthetic user message is injected with the content blocks:

```
[text] "Attached from read_file: /Users/alice/Desktop/diagram.png"
[image] <base64>
```

This is OpenCode's pattern for non-Anthropic providers and is the only thing that reliably works across local inference stacks.

## Background bash (Tier 2)

- `BackgroundProcess` actor holds registry keyed by handle: `{pid, command, started_at, stdout_buf, stderr_buf, exit_code, status}`.
- Output piped into ring buffers (30 KB each).
- On exit, the harness injects a channel message with `source="bash_complete"` — same pattern as reminders and email alerts — which triggers a new agent turn. Payload: handle, command, exit_code, tail of output.
- Every turn's system prompt includes a live-process summary: `Live processes: bash_1 (npm run dev, running 3m)`.
- Lifecycle tied to the app process. When LocalAgent quits, background processes terminate.

## Breadcrumb migration

Phase 6 (shipped):
- Both FractalMind summarization prompts (chunk-level in `summarizeConversationChunk`, meta-summary in `generateHistoricalMetaSummary`) now include an explicit rule: **"If the conversation mentions files by absolute path, preserve every absolute path verbatim — do not abbreviate, truncate, or replace with filenames alone."**
- The downloaded-files breadcrumb in `OpenRouterService` now references `read_file` instead of the removed `read_document`, and handles both legacy filenames and absolute paths (the field stores whichever was recorded).
- `list_recent_files` is advertised alongside the breadcrumb so the agent knows how to locate a file it can't resolve directly.

Deferred (future cleanup):
- Routing the remaining file-download call sites (`queueFileForDescription` from email, URL download, image gen, etc.) through `FilesLedger.record` with an absolute path and a specific origin (`.email`, `.download`, `.generated`). Currently these paths are discoverable via `list_recent_files` only for files written through the new tools; email and URL attachments remain on the legacy filename-only breadcrumb until this migration happens. Low risk, medium effort.

## Counterintuitive decisions

- `edit_file` AND `apply_patch` coexist. Local models vary in patch-syntax reliability. Give both; the model picks.
- Skip MultiEdit — OpenCode's is non-atomic, apply_patch does the same job correctly.
- Skip tree-sitter bash parsing — OpenCode's most sophisticated feature, but it exists only to scope permission prompts. We have no permission layer.
- Skip a `task` / sub-agent tool. The existing `run_claude_code` / `run_codex` / `run_gemini_cli` tools already delegate to real coding agents. Don't nest.
- Keep `edit_file`'s fuzzy fallback chain short (3 strategies, not OpenCode's 9). Strict errors teach local models faster than forgiving matchers.
- Ledger tracks writes only, not reads. Prevents bloat when a debug session reads the same file 50 times.

## Phased rollout

1. Foundation: FileTime actor, files_ledger.json, landing zone creation.
2. Core filesystem tools: read_file, write_file, edit_file, apply_patch, grep, glob, list_dir, list_recent_files.
3. Bash family: foreground + Tier 2 background with `bash_complete` channel injection.
4. Wire into ToolExecutor + OpenRouterService tool definitions + system prompt.
5. Remove the 6 old sandboxed tools.
6. Breadcrumb format migration.
7. Build + smoke test via Telegram.

## Unchanged infrastructure

Keep intact: Telegram bot + voice transcription, FractalMind archival, prompt cache optimization, dual-model routing, reminders, calendar, email, image gen (nano-banana), web search, deep research, Vercel, InstantDB, project management (manage_projects, run_claude_code, etc.).
