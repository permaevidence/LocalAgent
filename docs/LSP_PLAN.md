# LSP Integration Plan — LocalAgent

Handoff document for a future session to implement full Language Server Protocol support. Read this first, then `docs/ARCHITECTURE_PLAN.md` for context. The user is Matteo Ianni (Telegram: 1641309608); he authorized this work on 2026-04-13.

## Why LSP

Without LSP, LocalAgent writes code and has no idea if it compiles. It can ship broken Swift/TypeScript/Python and only find out if the user runs it. With LSP, every `write_file` / `edit_file` / `apply_patch` triggers a real type-check and the agent sees errors/warnings immediately — same quality bar as Claude Code, OpenCode, Cursor. This is the single biggest remaining gap between LocalAgent and the top OSS coding agents.

## Reference implementation

Mirror **OpenCode** (github.com/sst/opencode). Its LSP module is ~1500 lines of TypeScript under `packages/opencode/src/lsp/`. Clean architecture, MIT-licensed, production-grade. Read `client.ts`, `server.ts`, `index.ts` before coding. Do NOT copy wholesale — translate the architecture into idiomatic Swift actors.

Do NOT use Claude Code's LSP (closed source), Cursor's (closed), or Cody's (VS Code-coupled).

## Architecture

Three actors:

### `LSPClient` actor
Owns exactly one language-server subprocess.

Responsibilities:
- Spawn the server via `Process` with stdin/stdout pipes (stderr to log).
- Frame messages per LSP spec: `Content-Length: N\r\n\r\n<json>`.
- JSON-RPC request/response correlation by integer id; continuations resolve when the matching response arrives.
- Fire-and-forget notifications (no id, no response).
- Collect asynchronous `textDocument/publishDiagnostics` notifications into a URI-keyed dictionary.
- Handshake: `initialize` request with root URI + capabilities, then `initialized` notification.
- Graceful shutdown: `shutdown` request then `exit` notification, then terminate the process.
- Crash recovery: if the reader loop errors, mark the client dead; registry re-spawns on next request.

Public API (minimum):
```swift
func initialize(rootURI: URL, capabilities: ClientCapabilities) async throws
func didOpen(uri: URL, text: String, languageId: String) async
func didChange(uri: URL, text: String, version: Int) async
func didSave(uri: URL) async
func diagnostics(for uri: URL, waitFor: TimeInterval = 1.0) async -> [Diagnostic]
func shutdown() async
var isAlive: Bool { get }
```

### `LSPRegistry` actor
Maps `(language, workspaceRoot)` → `LSPClient`. Singleton.

Responsibilities:
- Detect language from file extension (see table below).
- Detect workspace root by walking up from the file path looking for markers (see table below).
- Spawn-on-demand: return existing client if alive, otherwise spawn+initialize.
- Idle TTL: reap clients with no activity for, say, 10 minutes.
- Expose a single entry point: `diagnostics(for path: String) async -> [Diagnostic]`.

### Integration points
After every successful write, call `LSPRegistry.shared.diagnostics(for: path)` and append any errors/warnings to the tool result content. Integration sites:
- `FilesystemTools.writeFile` (line ~155 in `FilesystemTools.swift`)
- `FilesystemTools.editFile` (line ~205)
- `ApplyPatch.commitPlan` — after each `.write` / `.add` / `.move` (in `ApplyPatch.swift`)

Format in tool result:
```json
{
  "success": true,
  "path": "...",
  "diagnostics": [
    {"line": 42, "col": 5, "severity": "error", "source": "sourcekit-lsp",
     "message": "cannot find 'foo' in scope"}
  ]
}
```

If `diagnostics` is present and non-empty with severity `error`, the agent should re-read and fix before continuing. If only warnings, surface but don't block.

## Language + server table

| Extension           | Language     | Server command                             | Install                                |
|---------------------|--------------|--------------------------------------------|----------------------------------------|
| `.swift`            | swift        | `sourcekit-lsp`                            | bundled with Xcode                     |
| `.ts`, `.tsx`, `.js`, `.jsx`, `.mjs`, `.cjs` | typescript | `typescript-language-server --stdio`       | `npm install -g typescript-language-server typescript` |
| `.py`               | python       | `pylsp`                                    | `pip install python-lsp-server`        |
| `.go`               | go           | `gopls`                                    | `go install golang.org/x/tools/gopls@latest` |
| `.rs`               | rust         | `rust-analyzer`                            | via `rustup component add rust-analyzer` |
| `.json`             | json         | `vscode-json-languageserver --stdio`       | `npm install -g vscode-json-languageserver` |

Resolve executables via the same helper as `DiscoveryTools.locateExecutable(_:)` — search `/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`, `/bin`, then `which`. If not found, the tool result should include `"diagnostics_skipped": "no language server available for .swift"` — never fail the write because of a missing server.

## Workspace root detection

Walk up from the file's directory looking for any of these markers. Stop at first match. Fall back to the file's own directory if none found.

| Language   | Markers                                               |
|------------|-------------------------------------------------------|
| swift      | `Package.swift`, `.xcodeproj`, `.xcworkspace`         |
| typescript | `tsconfig.json`, `jsconfig.json`, `package.json`      |
| python     | `pyproject.toml`, `setup.py`, `setup.cfg`, `requirements.txt` |
| go         | `go.mod`                                              |
| rust       | `Cargo.toml`                                          |
| json       | file's own directory                                   |

## JSON-RPC framing notes

Each message:
```
Content-Length: 123\r\n
\r\n
{"jsonrpc":"2.0", ...}
```

Reader loop must:
1. Read bytes until `\r\n\r\n` sequence, parse `Content-Length` from headers.
2. Read exactly N bytes of body.
3. Decode JSON, dispatch by id (response) or method (notification).
4. Handle partial reads on the pipe — use `FileHandle.readData(ofLength:)` in a dedicated thread or an async sequence over the pipe.

Writer must serialize writes (one at a time) with a lock/actor to prevent interleaved frames.

## LSP protocol — minimum subset

Client → server:
- `initialize` (request, id=1): `{processId, rootUri, capabilities, workspaceFolders}`
- `initialized` (notification)
- `textDocument/didOpen` (notification): `{textDocument: {uri, languageId, version, text}}`
- `textDocument/didChange` (notification): full-file sync, `{textDocument: {uri, version}, contentChanges: [{text}]}`
- `textDocument/didSave` (notification): `{textDocument: {uri}}`
- `shutdown` (request), then `exit` (notification)

Server → client (handle):
- `textDocument/publishDiagnostics` (notification): `{uri, diagnostics: [...]}`
- `window/logMessage`, `window/showMessage` — log and ignore
- `$/progress`, `client/registerCapability` — accept-and-ignore for MVP

## Capabilities to advertise (minimal)

```json
{
  "textDocument": {
    "synchronization": {"didSave": true, "willSave": false, "willSaveWaitUntil": false},
    "publishDiagnostics": {"relatedInformation": true}
  },
  "workspace": {"workspaceFolders": true}
}
```

## Known pitfalls

1. **Diagnostics arrive asynchronously.** After `didSave`, the server may take 200ms-2s to publish. The `diagnostics(for:waitFor:)` method needs to wait with a timeout, not return immediately.

2. **`textDocument/didChange` version numbers.** Start at 1, increment on every change. Mismatched versions → server desync.

3. **Full-text sync vs incremental.** MVP: use full-text sync (send the whole file in `contentChanges: [{text}]`). Incremental requires computing diff ranges — skip for v1.

4. **sourcekit-lsp needs `Package.swift` or Xcode project context** to resolve symbols cross-module. Without it, it only parses single files. Still useful — syntax errors and obvious type errors surface.

5. **typescript-language-server startup is slow** (~2-5 seconds). Idle-reap TTL should be generous (10+ min) to avoid repeated cold starts.

6. **pylsp plugins vary.** Default installation gives basic diagnostics. Add `pylsp-mypy` for type checks. Out of scope for v1.

7. **Server crashes** — not unusual for sourcekit-lsp on complex Swift. Wrap the reader loop in a do/catch; on crash, mark client dead and let the registry respawn.

8. **URI format:** `file:///absolute/path`. Use `URL(fileURLWithPath:).absoluteString` and double-check it starts with `file://`.

## Phased delivery

### Phase A — Core LSPClient
- `TelegramConcierge/Services/LSP/LSPClient.swift` (new)
- `TelegramConcierge/Services/LSP/JSONRPCFraming.swift` (new) — reader + writer helpers
- `TelegramConcierge/Services/LSP/LSPTypes.swift` (new) — minimal Codable types (Diagnostic, Position, Range, InitializeParams, etc.)
- Compiles and can be driven programmatically from a test harness. No integration yet.
- Add files to Xcode project (pbxproj edits, pattern is documented in the existing commit history — see commit 2114357).

### Phase B — LSPRegistry + language/workspace detection
- `TelegramConcierge/Services/LSP/LSPRegistry.swift` (new)
- `TelegramConcierge/Services/LSP/LSPLanguages.swift` (new) — extension → language + server command, markers → workspace root
- Idle reap via a timer or lazy-check on every call.

### Phase C — Integration into write tools
- Hook `FilesystemTools.writeFile`, `FilesystemTools.editFile`, `ApplyPatch.commitPlan`.
- Call `LSPRegistry.shared.diagnostics(for: path)` post-write, wait up to ~1s.
- Append `diagnostics` array to the tool result JSON.
- Update tool descriptions in `ToolModels.swift` to note that write operations now return diagnostics.

### Phase D — End-to-end smoke tests
- Swift: write a Swift file with a deliberate type error, verify sourcekit-lsp returns it.
- TypeScript: install typescript-language-server, write a `.ts` with a type error, verify.
- Python: install pylsp, write a `.py` with an undefined name, verify.

## Estimated time

- Phase A: ~1-2 hours of focused coding.
- Phase B: ~1 hour.
- Phase C: ~1 hour.
- Phase D: ~30 min each language end-to-end.

Total: 3-4 focused sessions, 4-5 hours of work.

## Starting conditions for the next session

- Current branch: `main` at commit `31205da` (line numbers) or newer.
- Create new branch: `feature/lsp-phase-a`.
- All prior filesystem tool work is merged and stable; don't revisit it unless a bug surfaces.
- Build command used throughout: `xcodebuild -project TelegramConcierge.xcodeproj -scheme TelegramConcierge -configuration Debug CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" build`
- Xcode project integration pattern (PBXBuildFile + PBXFileReference + Services group + Sources build phase) is the same as in the filesystem phases — grep existing commits for `FilesystemTools.swift` to see the four edit sites.

## What to tell the user in the first message of the next session

"Read `docs/LSP_PLAN.md` in the LocalAgent repo for the full scope. Ready to start Phase A (core LSPClient + JSON-RPC framing on a `feature/lsp-phase-a` branch), no integration yet. Expect one commit pushed at end of session with build green."
