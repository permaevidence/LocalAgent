# Native Subagent System

Reference for LocalAgent's built-in subagent support. Implemented across Phases 1–4
on the `feature/subagents` branch.

## Overview

A **subagent** is a fresh-context agent spawned by the parent via the `Agent` tool.
It runs its own LLM turn-loop with its own system prompt and an isolated tool
surface, and returns exactly one final message to the parent — no tool calls,
no intermediate reasoning, no blow-up of the parent's context window.

This is direct parity with Claude Code's `Task` / subagent system. LocalAgent
implements it natively on top of the same OpenRouter pipeline used by the parent,
plus an optional "cheap fast" model route for read-only exploration.

### Why it exists

- **Context containment** — a broad codebase sweep can produce megabytes of
  tool output. A subagent absorbs that inside its own window and only hands
  the parent a summary.
- **Focused prompts** — each subagent type gets a specialized system prompt
  that steers it (read-only, planning-only, etc.).
- **Cache isolation** — `Explore` uses a different API provider (Groq), so
  its prompt cache is entirely separate from the parent's Anthropic cache.
  A parent orchestrating five Explore calls in a row never evicts its own
  prefix.

## Architecture

```
  parent LLM turn
       │
       ▼  executes Agent(...)
  ToolExecutor.executeAgent
       │
       ├─── foreground ─▶ SubagentRunner.run → returns JSON result
       │
       └─── background ─▶ SubagentBackgroundRegistry.spawn
                                 │
                                 ▼  detached Task
                           SubagentRunner.run
                                 │
                                 ▼
                           markCompleted(...)
                                 │
                                 ▼ drained on next parent tick
                  ConversationManager polls registry,
                  injects `[SUBAGENT COMPLETE]` synthetic user msg,
                  wakes parent turn.
```

### Key files

| File | Role |
|------|------|
| `TelegramConcierge/Models/ToolModels.swift` | `Agent`, `list_running_subagents`, `cancel_subagent` tool definitions |
| `TelegramConcierge/Services/SubagentTypes.swift` | Built-in registry + `SubagentModelHintMapper` |
| `TelegramConcierge/Services/SubagentRunner.swift` | Actor that drives the subagent turn-loop |
| `TelegramConcierge/Services/SubagentBackgroundRegistry.swift` | Actor owning background `Task`s, handles, completions |
| `TelegramConcierge/Services/UserAgentLoader.swift` | Parses `~/LocalAgent/agents/*.md` |
| `TelegramConcierge/Services/ToolExecutor.swift` | Dispatches `Agent`, `list_running_subagents`, `cancel_subagent` |
| `TelegramConcierge/Services/ConversationManager.swift` | `checkBackgroundSubagentCompletions()` — drains completions, injects synthetic user msgs |

### Isolation model

A subagent is launched with:

- **No calendar context** — `calendarContext: nil`
- **No email context** — `emailContext: nil`
- **No chunk summaries** — `chunkSummaries: nil`
- **No prior conversation** — only the task prompt and the subagent's system suffix
- **No Agent tool in its own tool list** — so subagents cannot spawn subagents
- **Its own tool surface** — either a strict whitelist (for `Explore`, `Plan`,
  or user-defined via `tools:`) or "all parent tools minus `Agent`"

This is the "nil-context invariant" and must not regress. It is what makes
subagent runs cache-stable and predictable.

## Built-in subagent types

| Name | Whitelist | Max turns | Model | Use case |
|------|-----------|-----------|-------|----------|
| `general-purpose` | none (all parent tools minus `Agent`) | 20 | inherit | Open-ended focused task with full tool access |
| `Explore` | `read_file, grep, glob, list_dir, list_recent_files, lsp_*, web_fetch, web_search, bash` | 15 | `openai/gpt-oss-120b` via Groq/Vertex | Fast read-only codebase search with parallel tool calls |
| `Plan` | same whitelist as `Explore` | 20 | inherit | Produces a step-by-step implementation plan without executing |

`Explore`'s `bash` is allowed but the system prompt forbids any write/mutate shell
commands — it's there so the agent can do things like `wc -l` or `git grep`.

## User-defined agents

Drop a `.md` file into `~/LocalAgent/agents/`. It is picked up automatically on
every tool-list build (no restart needed). Name collisions with built-ins go to
the built-in.

### Frontmatter spec

```yaml
---
name: my-agent-name          # required, kebab-case, becomes subagent_type value
description: one-line text   # required, surfaced in tool schema
tools: read_file, grep, bash # optional — comma list or YAML list; omit to inherit all
model: inherit               # optional: inherit | cheapFast (default inherit)
max_turns: 20                # optional (default 20)
---
Everything below the closing --- is appended to the subagent's system prompt.
Write it as direct instructions to the agent.
```

### Full example

Path: `~/LocalAgent/agents/swift-lint-fixer.md`

```markdown
---
name: swift-lint-fixer
description: Fix SwiftLint warnings across the repo without changing behavior
tools: read_file, write_file, edit_file, grep, glob, bash
model: inherit
max_turns: 30
---
You are a focused Swift cleanup agent.

Your job: run SwiftLint, enumerate warnings by file, then fix them one file at a
time. Do NOT refactor logic. Only touch whitespace, unused imports, access-level
redundancies, and mechanical lint rules.

After each fix, re-run `swiftlint lint <file>` to confirm the warnings cleared.

Return: a summary of which warnings you fixed in which files, plus any warnings
you deliberately left (with reasoning).
```

The parent can now invoke: `Agent(subagent_type="swift-lint-fixer", description="clean warnings", prompt="clean all SwiftLint warnings under TelegramConcierge/Services/")`.

## Cache-safety invariants

These are the promises Phase 2/3 made about caching. They must be preserved:

1. **Nil context for subagents.** Never pass calendar/email/chunks into a
   subagent OpenRouter call. The subagent's system prompt is a one-time
   composition of (persona intro, task prompt, type-specific suffix) — it is
   fully hashable and entirely stable within a run.
2. **Separate API for cheap model.** When `preferredModel == .cheapFast`, the
   Explore runs hit `openai/gpt-oss-120b` via `groq,google-vertex`. These
   providers have their own prompt-cache namespace — Explore traffic does not
   share a cache with the parent's Anthropic cache and cannot evict it.
3. **One-time prefix changes.** Discovery of a new user-defined agent changes
   the `Agent` tool's schema (its `subagent_type` enum gains a value). That
   invalidates the parent's system-prompt cache once, at next turn, not per
   subagent call.
4. **Live-summary placement.** `BackgroundProcessRegistry.liveSummaryText()`
   and `SubagentBackgroundRegistry.liveSummary()` are appended near the end of
   the system prompt (after the cache-stable persona/calendar/email/chunks
   block, before the tools-usage footer). They're per-turn dynamic by design;
   treat them as the dynamic tail, not something to try to cache.

## Background mode

Pass `run_in_background="true"` to `Agent`. Semantics:

1. `SubagentBackgroundRegistry.spawn(...)` returns a `Handle` immediately.
   The tool result the parent sees is:

   ```json
   {
     "background": true,
     "handle": "subagent_1",
     "subagent_type": "Explore",
     "description": "find auth code",
     "note": "Subagent is running in the background. You will receive a synthetic [SUBAGENT COMPLETE] user message when it finishes. Continue with other work or wait."
   }
   ```

2. A detached `Task` drives `SubagentRunner.run` to completion. When done it
   calls `markCompleted(id:result:)` on the registry.

3. `ConversationManager.pollLoop` wakes every few seconds. On each tick it
   calls `checkBackgroundSubagentCompletions()` which:
   - drains `pendingCompletions`,
   - formats each as a synthetic user message starting with `[SUBAGENT COMPLETE]`,
   - appends it to the conversation,
   - kicks off a new agent turn (only when `activeRunId == nil`).

4. The parent LLM sees the synthetic message like a user message and can react
   (reply on Telegram, schedule follow-up work, spawn another subagent, etc.).

## Tools reference

### `Agent`

Spawn a new subagent.

Required: `subagent_type`, `description`, `prompt`.
Optional: `run_in_background` (`"true"` / `"false"`), `model` (`sonnet` | `opus` | `haiku` | `inherit`).

Foreground example:

```
Agent(
  subagent_type="Explore",
  description="find auth",
  prompt="Find every file that handles authentication or authorization. Return file paths and line numbers."
)
```

Background example:

```
Agent(
  subagent_type="Plan",
  description="design refactor",
  prompt="Produce an implementation plan for extracting OpenRouterService's system-prompt builder into its own file.",
  run_in_background="true"
)
```

### `list_running_subagents`

No parameters. Returns a JSON array of every currently-running background
subagent.

```json
{
  "count": 2,
  "running": [
    {"handle": "subagent_1", "subagent_type": "Explore", "description": "find auth code",
     "started_at": "2026-04-14T12:03:01Z", "running_seconds": 42},
    {"handle": "subagent_3", "subagent_type": "Plan",    "description": "design refactor",
     "started_at": "2026-04-14T12:03:45Z", "running_seconds": 8}
  ]
}
```

### `cancel_subagent`

Takes a single `handle`. Cancels best-effort — the underlying `Task` is
cancelled, but the subagent's current turn finishes first, then exits at the
next loop boundary. A `[SUBAGENT COMPLETE]` still arrives, and will reflect
the truncated state.

```json
{"cancelled": true, "handle": "subagent_1",
 "note": "Cancellation requested. Takes effect at the subagent's next turn boundary — you will still receive a [SUBAGENT COMPLETE] message."}
```

## What is intentionally NOT supported

- **Nested subagents.** The Agent tool is removed from the subagent's own tool
  surface, so a subagent cannot spawn another subagent. This prevents recursion
  blow-ups and keeps cost predictable.
- **Worktree isolation / sandboxed filesystem.** Skipped as of Phase 3.
  Subagents read and write against the same filesystem as the parent. If the
  parent is mid-edit on a file, a subagent can race with it. In practice this
  hasn't been a problem because Explore and Plan are read-only.
- **Cross-subagent messaging.** Subagents cannot talk to each other. Use
  the parent as a router if you need that.

---

## End-to-end smoke tests

Paste each of these into Telegram on the test machine to verify the system.
They are written verbatim — copy exactly.

### Test 1 — Basic Explore

> Use the Agent tool with subagent_type='Explore', description='find auth code', prompt='find any file in the current repo that appears to handle authentication or authorization. Report file paths and line numbers.'. Show me the JSON tool result.

Expected: a JSON object with `success: true`, a `summary` field with findings,
and `turns_used` ≤ 15. No modifications to the filesystem.

### Test 2 — Plan

> Use the Agent tool with subagent_type='Plan', description='plan logger refactor', prompt='Produce a step-by-step implementation plan for extracting all print()/FileHandle.standardError.write debug logging in TelegramConcierge/Services into a single Logger type. Include: critical files to touch, sequencing, risks, and rollout order. Do NOT make any changes.'. Show me the plan verbatim.

Expected: a structured multi-step plan with numbered steps, file list, risks,
and rollout order. No files touched.

### Test 3 — Background subagent

> Use the Agent tool with subagent_type='Explore', description='deep lsp scan', prompt='Walk every Swift file under TelegramConcierge/Services. For each file, note its primary type and a one-sentence purpose. Return a markdown table.', run_in_background='true'. Reply to me immediately with just the handle string once you get it, then wait — you should receive a synthetic [SUBAGENT COMPLETE] message unprompted within a minute. When that arrives, message me the summary.

Expected: parent replies with `subagent_1` (or similar) within seconds. A
`[SUBAGENT COMPLETE]` synthetic user message is injected ~30–90s later and the
parent sends an unprompted Telegram reply with the table.

### Test 4 — User-defined agent

Paste this in your terminal first:

```bash
mkdir -p ~/LocalAgent/agents && cat > ~/LocalAgent/agents/test.md <<'EOF'
---
name: repo-stats
description: Return counts of Swift files and total lines
tools: bash, glob
model: inherit
max_turns: 5
---
You are a repo stats reporter. Run `find . -name '*.swift' -not -path '*/.*' | wc -l` for the file count and `find . -name '*.swift' -not -path '*/.*' -exec wc -l {} + | tail -1` for the total lines, then return exactly two lines: "files: N" and "lines: N".
EOF
```

Then on Telegram:

> Use the Agent tool with subagent_type='repo-stats', description='count swift', prompt='Run your standard stats on the current working directory.'. Reply with just the two lines from the agent.

Expected: a reply with `files: N` and `lines: N` (two integers).

### Test 5 — Cancel

> Use the Agent tool with subagent_type='Explore', description='long scan', prompt='Read every file under TelegramConcierge/ one at a time and return a single-sentence summary of each. Do not use parallel tool calls.', run_in_background='true'. Immediately after you get the handle, call cancel_subagent on that handle. Reply to me with the handle you cancelled. Then wait for the [SUBAGENT COMPLETE] and tell me whether it arrived and whether the summary indicates truncation.

Expected: parent replies with the handle and "cancelled". A
`[SUBAGENT COMPLETE]` arrives shortly after (seconds, not minutes) with a
partial/empty summary, confirming cancellation took effect.
