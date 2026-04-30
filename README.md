# LocalAgent

A native macOS application that turns any LLM into an autonomous personal agent. It connects to you via Telegram, manages your files, browses the web, generates images, transcribes voice messages, orchestrates subagents, integrates with external tool servers via MCP, and remembers everything across sessions — powered by any model available through OpenRouter or running locally via any OpenAI-compatible inference server.

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2014+-blue" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Swift-5.9-orange" alt="Swift 5.9">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="License">
</p>

---

## Features

### LLM Provider Flexibility
- **OpenRouter** — access Gemini, Claude, GPT, DeepSeek, Qwen, Grok, and hundreds more through a single API key
- **Local inference** — run models on your own hardware via any OpenAI-compatible server (LM Studio, Ollama, vLLM, llama.cpp, etc.) with automatic KV cache preservation
- **Configurable reasoning effort** — adjust thinking depth per model
- **Provider enforcement** — pin requests to specific providers with strict routing (no silent fallbacks)

### Full-Autonomy Tool Use
- **25+ built-in tools** — the LLM autonomously decides when and how to use them
- **Parallel tool execution** — independent tool calls dispatch concurrently
- **Agentic loop** — the model runs iteratively: call tools, observe results, call more tools, until it has a final answer
- **Multimodal** — natively handles images, PDFs (with page-level navigation), audio, and documents sent via Telegram
- **PDF rendering** — automatic PDF-to-PNG conversion for models that lack native PDF support (everything except Gemini on OpenRouter)

### Persistent Memory (FractalMind)
- **Tiered archival** — conversation history is automatically chunked, summarized by the LLM, and consolidated over time
- **User context** — learns and persists facts about you across sessions
- **Semantic search** — the agent can search its own memory for past conversations
- **Mind export/import** — full data portability via `.mind` files
- **Crash-safe** — pending chunks survive app restarts

### Precision Token Management
- **API-measured token counts** — per-message costs derived from real API response data (prompt_tokens / completion_tokens deltas), not heuristic estimates
- **Two-threshold pruning** — when context exceeds the high watermark (default 200k), tool interactions, reasoning, and media are pruned chronologically from oldest messages until the low watermark (default 70k) is reached
- **Lazy file descriptions** — files are described by the LLM only at prune time (not eagerly), so the compact summary replaces the heavy media payload with zero wasted API calls
- **Tool attachment persistence** — images and PDFs produced by tools persist across turns via lightweight file references, reloaded from disk snapshots for bit-identical prompt caching
- **Live context gauge** — the chat UI shows real-time token usage (e.g. "83.5k/100k") with color-coded warnings

### Native Subagents
- Spawn isolated-context subagents via the `Agent` tool
- Built-in types: `general-purpose`, `Explore` (cheap, fast model for codebase sweeps), `Plan` (architectural reasoning)
- User-defined agents via `~/LocalAgent/agents/*.md` with YAML frontmatter
- Foreground or background execution — background agents report back via synthetic injection when complete
- Subagents run in separate cache namespaces to avoid evicting the parent's prompt cache

### Model Context Protocol (MCP)
- Connect external tool servers (Playwright, Postgres, custom servers) via `~/LocalAgent/mcp.json`
- **Per-agent routing** — each agent (main, Browse, Plan, etc.) has independent Always/Deferred/Disabled toggles per MCP server
- **Deferred discovery** — MCP tools hidden from the main context are discoverable on-demand via `tool_search` and executed via `mcp_call`, saving thousands of tokens per turn
- Keychain-backed secret injection into server environments

### Language Server Protocol (LSP)
- Integrated LSP client for code intelligence (hover, go-to-definition, find-references)
- Supports sourcekit-lsp, typescript-language-server, pylsp, and more
- Post-edit diagnostics — errors and warnings from the language server are injected directly into tool results

### Skills System
- Procedural guides that teach the agent domain-specific workflows
- Bundled skills: PDF, DOCX, XLSX, PPTX, video editing
- User-defined skills in `~/LocalAgent/skills/*.md`
- Hot-reloaded — drop a file and the agent can use it immediately

### Filesystem and Terminal
- Full filesystem access — read, write, edit files by absolute path
- Atomic multi-file patches with rollback
- Ripgrep-powered search, glob pattern matching, directory listing
- Background shell processes with regex-based watch triggers
- File ledger tracking recently touched files

### Web and Research
- Google search via Serper, web page reading via Jina
- Multi-source research sweeps
- File downloads from any URL

### Communication
- **Telegram** — the primary interface; supports text, voice messages, images, files, and documents
- **Google Workspace** — Gmail, Calendar, Drive, and Contacts via the `gws` CLI
- **Reminders** — natural language scheduling with recurrence; the agent can set reminders for itself to follow up on tasks

### Image Generation
- Powered by Gemini (`gemini-3-pro-image-preview`)
- Generate and iteratively refine images from text prompts

### Voice Transcription
- On-device via WhisperKit (CoreML-optimized for Apple Silicon)
- Or cloud-based via OpenAI (`gpt-4o-transcribe`)
- Send voice messages in Telegram and the agent receives the transcript

### macOS Integration
- List and run macOS Shortcuts from Telegram
- Privacy mode (`/hide` / `/show`) to conceal the UI when someone has physical access to your Mac
- All credentials stored in the macOS Keychain — nothing on disk

---

## Architecture

```
                        Telegram User
                   (text, voice, files)
                           |
                           v
                    TelegramBotService
                  (long-polling, dispatch)
                           |
                           v
                   ConversationManager
             (agentic loop, history, pruning,
              archival, subagent coordination)
                    /              \
                   v                v
          OpenRouterService    ConversationArchive
          (LLM API, context     Service (FractalMind
           window, multimodal,   memory, tiered
           token tracking)       summarization)
                   |
                   v
              ToolExecutor
         (parallel dispatch, 25+ tools)
                   |
    +--------------+--------------+
    |              |              |
    v              v              v
 Filesystem    MCPRegistry     SubagentRunner
 + LSP         (external       (isolated context,
 + Bash        tool servers)   background exec)
    |              |              |
    v              v              v
 GoogleWorkspace  Playwright   User-defined
 WebOrchestrator  Postgres     agents from
 GeminiImage      Custom...    ~/LocalAgent/agents/
 WhisperKit
 Skills
 Reminders
```

### Key Design Decisions

- **Measured, not estimated** — token budgets use real API-reported prompt_tokens and completion_tokens via delta arithmetic, with heuristic fallback only for the first turn
- **Prompt cache optimization** — system prompt uses a frozen date-only timestamp; tool interactions persist as a stable prefix; media snapshots are bit-identical across turns
- **Lazy descriptions** — file summaries are generated at prune time, not eagerly, preventing wasted API calls for files that stay in context
- **Deferred MCP routing** — external tool schemas are loaded on-demand per agent, keeping the main context lean while retaining full functional reach
- **Keychain storage** — all API keys and secrets live in the macOS Keychain
- **No telemetry** — the app does not collect or transmit any usage data

---

## Tools

| Category | Tools |
|----------|-------|
| **Filesystem** | `read_file`, `write_file`, `edit_file`, `apply_patch`, `grep`, `glob`, `list_dir`, `list_recent_files` |
| **Terminal** | `bash`, `bash_manage` (output, input, watch, kill background processes) |
| **Code** | `lsp` (hover, definition, references via Language Server Protocol) |
| **Web** | `web_search`, `web_research_sweep`, `web_fetch` |
| **Agents** | `Agent` (spawn subagents), `subagent_manage` (list, cancel) |
| **MCP** | `tool_search` (discover schemas), `mcp_call` (invoke deferred tools) |
| **Memory** | `view_conversation_chunk`, `manage_reminders` |
| **Media** | `generate_image`, `send_document_to_chat` |
| **System** | `shortcuts` (macOS Shortcuts), `skill` (load procedural guides), `todo_write` (task tracking) |

---

## Project Structure

```
LocalAgent/
  TelegramConcierge/
    TelegramConciergeApp.swift          # Entry point (onboarding gate + MainView)
    Models/
      Message.swift                     # Conversation model (multimodal, token tracking)
      ToolModels.swift                  # Tool definitions (OpenAI function calling format)
      TelegramModels.swift              # Telegram API types
      ConversationArchiveModels.swift   # Memory chunk models
      ...
    Services/
      ConversationManager.swift         # Central orchestrator: agentic loop, pruning, archival
      OpenRouterService.swift           # LLM API: context window, multimodal, token deltas
      TelegramBotService.swift          # Telegram long-polling and dispatch
      ToolExecutor.swift                # Parallel tool dispatch
      ToolExecutor+Filesystem.swift     # File operation tools
      SubagentRunner.swift              # Isolated-context subagent execution
      MCPRegistry.swift                 # MCP server lifecycle and tool discovery
      MCPClient.swift                   # JSON-RPC transport for MCP
      MCPAgentRouting.swift             # Per-agent Always/Deferred/Disabled routing
      LSPRegistry.swift                 # Language server management
      LSPClient.swift                   # LSP protocol client
      GoogleWorkspaceService.swift      # Gmail, Calendar, Drive, Contacts via gws CLI
      ConversationArchiveService.swift  # FractalMind: chunking, summarization, consolidation
      WhisperKitService.swift           # On-device voice transcription
      GeminiImageService.swift          # Image generation
      WebOrchestrator.swift             # Web search and page reading
      FilesystemTools.swift             # File operations with PDF rendering
      BashTools.swift                   # Shell execution and background processes
      SkillsRegistry.swift              # Skills discovery and loading
      FileDescriptionService.swift      # Lazy AI-generated file descriptions
      MindExportService.swift           # .mind export/import
      ...
    Views/
      MainView.swift                    # Unified sidebar navigation (9 sections)
      ContentView.swift                 # Chat interface with token gauge
      OnboardingView.swift              # 9-step setup wizard
      SettingsView.swift                # Configuration panels
      AgentsSettingsView.swift          # Subagent and MCP routing configuration
      MCPsSettingsView.swift            # MCP server management (ON/OFF, config)
      SkillsSettingsView.swift          # Skills browser
      MessageBubbleView.swift           # Chat bubbles with multimodal previews
      ContextViewerView.swift           # Debug: inspect full LLM context
      DebugTelemetryPanel.swift         # Token counts, spend, diagnostics
    Resources/
      BundledSkills/                    # Built-in procedural guides (pdf, docx, xlsx, pptx, video-edit)
    Utilities/
      KeychainHelper.swift              # Secure credential storage
```

### User Data Directories

| Path | Purpose |
|------|---------|
| `~/LocalAgent/mcp.json` | MCP server configurations |
| `~/LocalAgent/mcp-routing.json` | Per-agent MCP tool routing |
| `~/LocalAgent/agents/*.md` | User-defined subagent definitions |
| `~/LocalAgent/skills/*.md` | User-defined procedural skills |
| `~/Library/Application Support/LocalAgent/` | Runtime data (conversation, archives, attachments, todos) |

---

## Getting Started

### Prerequisites

| Requirement | Notes |
|---|---|
| **macOS 14 Sonoma** or later | Apple Silicon recommended for local inference and WhisperKit |
| **Xcode 15+** | To build and run |
| A **Telegram** account | For creating the bot that serves as the interface |

### Quick Start

1. Clone the repository and open `TelegramConcierge.xcodeproj` in Xcode.
2. Build and run.
3. The app launches into a guided onboarding flow that walks you through:
   - Choosing an LLM provider (Local Inference or OpenRouter)
   - Setting up your persona (assistant name, your name, context about you)
   - Creating and connecting a Telegram bot
   - Optionally configuring voice transcription, web search, Google Workspace, and image generation
4. Once onboarding completes, open Telegram and send your bot a message.

### Telegram Commands

| Command | Description |
|---------|-------------|
| `/stop` | Interrupt current processing |
| `/spend` | View API spend summary |
| `/more1` `/more5` `/more10` | Temporarily raise spend limits |
| `/prune` | Manually prune tool interactions |
| `/hide` / `/show` | Toggle privacy mode on the Mac |
| `/transcribe_local` / `/transcribe_openai` | Switch voice transcription method |

---

## Security and Privacy

- **Keychain storage** — all API keys, tokens, and credentials are stored in the macOS Keychain
- **Chat ID filter** — the bot only responds to your Telegram user ID
- **Privacy mode** — `/hide` conceals the on-screen conversation and sensitive UI; `/show` restores it
- **Local voice processing** — WhisperKit transcription runs entirely on-device
- **No telemetry** — the app does not collect or transmit any usage data

---

## License

This project is open source and available under the [MIT License](LICENSE).

---

## Acknowledgments

- [OpenRouter](https://openrouter.ai) — unified LLM API gateway
- [LM Studio](https://lmstudio.ai) — local model inference (one of many compatible providers)
- [WhisperKit](https://github.com/argmaxinc/WhisperKit) — on-device speech recognition
- [Serper](https://serper.dev) — Google Search API
- [Jina AI](https://jina.ai) — web content extraction
