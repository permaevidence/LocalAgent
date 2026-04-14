# Telegram Concierge

A native macOS AI assistant that lives inside a Telegram bot you control. It reads and sends emails, searches the web, generates images, manages your calendar, transcribes voice messages, runs macOS Shortcuts, spawns native subagents (`Explore`, `Plan`, `general-purpose`, or custom), and remembers everything — powered by any LLM available through OpenRouter.

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2014+-blue" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Swift-5.9-orange" alt="Swift 5.9">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="License">
</p>

---

## ✨ Features

### 🤖 AI Core
- **Any LLM** via [OpenRouter](https://openrouter.ai) — Gemini, Claude, GPT, Grok, and more
- **Local inference** via [LM Studio](https://lmstudio.ai) — run models locally with automatic KV cache preservation
- **Configurable reasoning effort** — adjust thinking depth per model
- **Full tool-use (function calling)** — the LLM autonomously decides when and how to use over 30 tools
- **Multimodal** — understands images, PDFs, audio, and documents you send via Telegram
- **Prompt cache optimization** — tool interactions persist across turns, system prompt stays stable, and a two-threshold pruning system keeps context within budget while maximizing cache hit rates
- **Remote privacy mode** — send `/hide` from Telegram to hide conversations and other sensitive UI on the Mac until `/show` is sent

### 🧠 Persistent Memory (FractalMind)
- **Tiered chunking** — conversation history is automatically archived into chunks, summarized by the LLM, and consolidated over time
- **Crash-safe archival** — pending chunks survive app restarts
- **Semantic search** — the AI can search its own memory for past conversations
- **User context** — learns facts about you over time and persists them across sessions
- **Mind export/import** — full data portability: download or restore your entire assistant state as a `.mind` file

### 📧 Email
- **Gmail API** *(recommended)* — fast, efficient, thread-aware email with OAuth2
- **IMAP/SMTP** — alternative for non-Gmail setups
- **Full lifecycle** — read, search, compose, reply, forward, download attachments, send with attachments
- **Background monitoring** — the AI is aware of your latest inbox activity

### 📅 Calendar
- View, add, edit, and delete calendar events
- Calendar context is injected into every system prompt so the AI always knows your schedule
- Export/import calendar data independently

### 🌐 Web
- **Google search** via [Serper](https://serper.dev)
- **Web page reading** via [Jina](https://jina.ai)
- **Page image viewing** — the AI can selectively download and analyze images from web pages
- **File downloads** — download files from any URL

### 🖼️ Image Generation
- Powered by **Gemini** (`gemini-3-pro-image-preview`)
- Iterative improvement — the AI can see and refine its own generated images

### 🎙️ Voice Transcription
- On-device transcription using **WhisperKit** (`whisper-large-v3-turbo`)
- CoreML-optimized for Apple Silicon
- Send voice messages in Telegram and the AI receives the transcript

### 🤖 Native Subagents
- Spawn isolated-context subagents via the `Agent` tool — built-in types `Explore`, `Plan`, `general-purpose`, plus any user-defined agent from `~/LocalAgent/agents/*.md`
- Foreground or background: pass `run_in_background='true'` to get a handle back immediately; the parent continues working and is notified via a synthetic `[SUBAGENT COMPLETE]` message when the subagent exits
- Introspect and steer with `list_running_subagents` and `cancel_subagent`
- `Explore` routes to a separate cheap model (Groq `openai/gpt-oss-120b`) in its own prompt-cache namespace, so a broad codebase sweep never evicts the parent's cached prefix
- See [`docs/SUBAGENTS_PLAN.md`](docs/SUBAGENTS_PLAN.md) for architecture, YAML frontmatter spec, and end-to-end smoke tests

### ⚡ macOS Shortcuts
- List and run any macOS Shortcut from Telegram
- Pass input and receive output programmatically

### 📇 Contacts
- Import contacts from `.vcf` (vCard) files
- Search, add, list, and delete contacts
- Used by the AI when composing emails to find addresses

### ⏰ Reminders & Self-Orchestration
- Set reminders with natural language
- Recurring reminders (daily, weekly, monthly, yearly)
- **Self-orchestration** — the AI proactively sets reminders for itself to follow up on tasks

### 📄 Document Handling
- Read and analyze documents (PDF, DOCX, XLSX, CSV, TXT, and more)
- Generate documents (PDF, spreadsheet, text) and send them via Telegram or email
- Multimodal analysis of images sent as documents

---

## 🏗️ Architecture

```
┌──────────────────────────────────────────────────┐
│                  Telegram User                   │
│             (messages, voice, files)             │
└─────────────────────┬────────────────────────────┘
                      │
                      ▼
┌──────────────────────────────────────────────────┐
│              TelegramBotService                  │
│          (long-polling, message dispatch)         │
└─────────────────────┬────────────────────────────┘
                      │
                      ▼
┌──────────────────────────────────────────────────┐
│            ConversationManager                   │
│    (message history, agentic loop, archival)     │
├──────────────────────────────────────────────────┤
│  OpenRouterService    │  ConversationArchive     │
│  (LLM API + context   │  Service (FractalMind    │
│   window management)  │  memory & summarization) │
└───────────┬──────────┴───────────────────────────┘
            │
            ▼
┌──────────────────────────────────────────────────┐
│               ToolExecutor                       │
│        (parallel tool dispatch, 30+ tools)       │
├──────────────────────────────────────────────────┤
│ EmailService / GmailService                      │
│ CalendarService      │ ReminderService           │
│ WebOrchestrator      │ GeminiImageService        │
│ DocumentService      │ DocumentGeneratorService  │
│ ContactsService      │ WhisperKitService         │
│ MindExportService    │ Code CLI (subprocess)     │
│ macOS Shortcuts      │ User Context Management   │
└──────────────────────────────────────────────────┘
```

### Key Design Decisions

- **Agentic loop** — the LLM runs iteratively: it can call tools, observe results, then call more tools until it has a final answer
- **Parallel tool execution** — multiple independent tool calls are dispatched concurrently
- **Tool interaction persistence** — tool calls and results are stored on assistant messages across turns, enabling prompt cache reuse between turns (see below)
- **Token-budget context management** — a two-threshold system (max trigger / prune target, default 100K/50K) collapses stored tool interactions from oldest turns when context grows too large, while FractalMind archival independently manages conversation text weight
- **Prompt cache optimization** — system prompt uses a frozen date-only timestamp that refreshes only on prune events or day boundaries; combined with stable message history prefix, this maximizes prompt cache hit rates across consecutive API calls
- **Keychain storage** — all API keys and secrets are stored in the macOS Keychain, never on disk
- **Sandbox-aware** — runs in the macOS app sandbox with network, audio input, and Apple Events entitlements

---

## 🛠️ Available Tools

<details>
<summary><strong>📧 Email (8 IMAP tools / 2 Gmail tools)</strong></summary>

| Tool | Description |
|------|-------------|
| `read_emails` / `gmailreader` | Read Gmail: search/list emails, read full messages or threads, and download attachments |
| `search_emails` | Advanced search across all folders |
| `send_email` / `gmailcomposer` | Compose Gmail: send new emails, reply in-thread, or forward with attachments |
| `reply_email` | Reply to a specific email in-thread |
| `forward_email` | Forward emails with attachments |
| `get_email_thread` | View full email conversation thread |
| `send_email_with_attachment` | Send email with documents from storage |
| `download_email_attachment` | Download email attachments for analysis |

</details>

<details>
<summary><strong>📅 Calendar (4 tools)</strong></summary>

| Tool | Description |
|------|-------------|
| `view_calendar` | View upcoming (and optionally past) events |
| `add_calendar_event` | Create a new event with title, datetime, duration, notes |
| `edit_calendar_event` | Modify an existing event |
| `delete_calendar_event` | Remove an event |

</details>

<details>
<summary><strong>🌐 Web (4 tools)</strong></summary>

| Tool | Description |
|------|-------------|
| `web_search` | Search the web via Google (Serper) |
| `web_fetch` | Fetch a URL and extract a prompt-focused excerpt (mandatory prompt, 15-min LRU cache, Claude Code parity) |
| `web_fetch_image` | Download and view a specific image from a web page |
| `download_from_url` | Download any file from a URL |

</details>

<details>
<summary><strong>📄 Documents (4 tools)</strong></summary>

| Tool | Description |
|------|-------------|
| `read_document` | Read/analyze any stored document (PDF, images, etc.) |
| `list_documents` | List stored documents by recent usage with pagination (`limit`, `cursor`) |
| `generate_document` | Generate PDF, spreadsheet, or text documents |
| `send_document_to_chat` | Send a document file to the Telegram chat |

</details>

<details>
<summary><strong>💻 Filesystem & Terminal (15 tools)</strong></summary>

| Tool | Description |
|------|-------------|
| `read_file` | Read any file by absolute path (with optional line range) |
| `write_file` | Create or overwrite a file |
| `edit_file` | Targeted in-place edit by old_string / new_string |
| `apply_patch` | Apply a unified-diff patch atomically across one or more files |
| `grep` | Ripgrep-style regex search across the filesystem |
| `glob` | Glob file pattern matching |
| `list_dir` | List directory entries with file/dir distinction |
| `list_recent_files` | Show recently written / received files via the in-app ledger |
| `bash` | Run a shell command (foreground 120s default; `run_in_background=true` for detached + handle) |
| `bash_output` | Peek at a background bash handle's accumulated stdout/stderr |
| `bash_kill` | Terminate a background bash handle (SIGTERM → SIGKILL) |
| `bash_watch` | Subscribe to a regex against a running bash handle's stdout/stderr — fires a synthetic `[BASH WATCH MATCH]` message when matched. Use to react mid-stream to dev-server logs, install errors, or progress milestones without polling. |
| `lsp_hover` / `lsp_definition` / `lsp_references` | Sourcekit-LSP-backed code intelligence over Swift sources |

</details>

<details>
<summary><strong>🤖 Subagents (3 tools)</strong></summary>

| Tool | Description |
|------|-------------|
| `Agent` | Spawn a fresh-context subagent (`general-purpose`, `Explore`, `Plan`, or any user-defined type from `~/LocalAgent/agents/*.md`). Subagents have isolated context windows and return a single final message. Pass `run_in_background='true'` to get a handle immediately and continue; a synthetic `[SUBAGENT COMPLETE]` message arrives when it finishes. |
| `list_running_subagents` | List every subagent currently running in the background: handle, type, description, started_at, running_seconds. |
| `cancel_subagent` | Cancel a background subagent by handle. Takes effect at the next turn boundary. |

See [`docs/SUBAGENTS_PLAN.md`](docs/SUBAGENTS_PLAN.md) for the full design.

</details>

<details>
<summary><strong>🧠 Memory & Context (4 tools)</strong></summary>

| Tool | Description |
|------|-------------|
| `view_conversation_chunk` | Browse archived conversation history |
| `add_to_user_context` | Save a learned fact about the user |
| `remove_from_user_context` | Remove outdated information |
| `rewrite_user_context` | Rewrite the full user context |

</details>

<details>
<summary><strong>⚡ System (5 tools)</strong></summary>

| Tool | Description |
|------|-------------|
| `set_reminder` | Schedule a one-time or recurring reminder |
| `list_reminders` | View pending reminders |
| `delete_reminder` | Cancel a reminder |
| `shortcuts` | List available macOS Shortcuts or run one with optional input |
| `generate_image` | Generate an image from a text prompt |
| `find_contact` | Search contacts by name or email |
| `add_contact` | Add a new contact |
| `list_contacts` | List all contacts |

</details>

---

## 📦 Project Structure

```
TelegramConcierge/
├── TelegramConciergeApp.swift      # App entry point
├── Models/
│   ├── Message.swift               # Conversation message model (multimodal)
│   ├── ToolModels.swift            # Tool definitions (OpenAI function calling format)
│   ├── TelegramModels.swift        # Telegram API response models
│   ├── DocumentModels.swift        # Document generation types
│   ├── ConversationArchiveModels.swift  # Memory chunk models
│   ├── CalendarEvent.swift         # Calendar event model
│   ├── Contact.swift               # Contact model
│   └── Reminder.swift              # Reminder model (with recurrence)
├── Services/
│   ├── ConversationManager.swift   # Central orchestrator: agentic loop, history, archival
│   ├── OpenRouterService.swift     # LLM API: context window, multimodal, tool calls
│   ├── TelegramBotService.swift    # Telegram bot long-polling and message dispatch
│   ├── ToolExecutor.swift          # Tool dispatcher (30+ tools, parallel execution)
│   ├── ConversationArchiveService.swift  # FractalMind memory: chunking, summarization
│   ├── EmailService.swift          # IMAP/SMTP email client
│   ├── GmailService.swift          # Gmail API client (OAuth2)
│   ├── WebOrchestrator.swift       # Multi-step web search + scraping
│   ├── GeminiImageService.swift    # Image generation (Gemini)
│   ├── WhisperKitService.swift     # On-device voice transcription
│   ├── CalendarService.swift       # Calendar CRUD
│   ├── ContactsService.swift       # Contact management
│   ├── ReminderService.swift       # Reminder scheduling
│   ├── DocumentService.swift       # Document storage
│   ├── DocumentGeneratorService.swift  # PDF/spreadsheet/text generation
│   ├── MindExportService.swift     # Full-state data portability
│   └── FileDescriptionService.swift    # AI-generated file descriptions
├── Views/
│   ├── ContentView.swift           # Main chat interface
│   ├── SettingsView.swift          # Configuration panel
│   ├── MessageBubbleView.swift     # Chat bubble with file previews
│   └── ContextViewerView.swift     # Debug: view full Gemini context
└── Utilities/
    └── KeychainHelper.swift        # Secure credential storage
```

---

## 🚀 Getting Started

### Prerequisites

| Requirement | Notes |
|---|---|
| **macOS 14 Sonoma** or later | Apple Silicon recommended for WhisperKit |
| **Xcode 15+** | To build and run the project |
| A **Telegram** account | For creating the bot |

### Quick Start

1. Clone the repository:
   ```bash
   git clone https://github.com/YOUR_USERNAME/telegram-concierge.git
   ```
2. Open `TelegramConcierge.xcodeproj` in Xcode.
3. Build and run (⌘R).
4. Open **Settings** (⌘,) and follow the [**Setup Guide**](SETUP.md) to configure your API keys.

> [!TIP]
> The full setup guide walks you through each section step by step — from creating your Telegram bot to configuring email, voice transcription, and Code CLI providers.

---

## 🔐 Security & Privacy

- **Keychain storage** — all API keys, tokens, and credentials are stored in the macOS Keychain. Nothing touches the file system.
- **Chat ID filter** — the bot only responds to your Telegram user ID, rejecting all other messages.
- **Remote screen privacy** — send `/hide` in Telegram to hide the on-screen conversation, Persona section, context viewer, and export actions on the Mac if someone can access your desktop computer. Send `/show` to restore them.
- **App Sandbox** — the app runs inside the macOS sandbox with only the required entitlements (network, audio input, Apple Events for Shortcuts).
- **Local processing** — voice transcription runs entirely on-device via WhisperKit. No audio leaves your Mac.
- **No telemetry** — the app does not collect or transmit any usage data.

---

## 🧠 How Memory Works

Telegram Concierge uses a tiered memory system inspired by how human memory works:

1. **Active context** — the most recent conversation messages plus their tool interactions, sent directly to the LLM. Total context is managed by a configurable token budget (default 100K max).
2. **Tool interaction persistence** — tool calls and results from each turn are stored on the assistant message and included in subsequent API calls. This creates a stable message prefix that enables prompt caching across turns. When the context budget is exceeded, tool interactions are pruned from the oldest turns first (down to the target, default 50K), while the most recent turn is always protected.
3. **Compact tool logs** — when tool interactions are pruned, a lightweight summary of what tools were used replaces them. Up to 5 active logs are retained as system-role context so the LLM still knows what happened in those turns.
4. **Temporary chunks** (~10k tokens each) — when conversation text weight (excluding tool interactions) overflows, the oldest messages are archived into a chunk and summarized by the LLM. This is independent of the tool interaction budget.
5. **Consolidated chunks** (~40k tokens each) — when 6 temporary chunks accumulate, the oldest 4 are merged into a larger consolidated chunk with a richer summary.
6. **User context** — persistent facts about you (preferences, relationships, details), learned automatically during archival or via the `add_to_user_context` tool. Restructured at consolidation time to remove duplicates.
7. **Chunk summaries in system prompt** — summaries of recent chunks are always visible to the AI, so it knows what was discussed even if the raw messages are no longer in context.
8. **Deep search** — the AI can retrieve and read full archived chunks when it needs to recall specific details.

### Prompt Caching

The architecture is designed to maximize prompt cache hit rates:

- **Frozen system prompt** — the date in the system prompt updates only on prune events or day boundaries, not on every turn. The current time comes from message timestamps instead.
- **Stable history prefix** — tool interactions stored on messages become part of the cacheable prefix. Between prune events, the prefix is byte-identical across API calls.
- **LM Studio KV cache** — for local inference, a separate description model can be configured to prevent file description calls from evicting the main model's KV cache. Web search calls always go through OpenRouter and never touch the local cache.
- **Anthropic cache control** — breakpoints are placed on the system prompt and the last historical message for explicit cache reuse during agentic tool loops.

### Telegram Commands

| Command | Description |
|---------|-------------|
| `/stop` | Interrupt the current processing |
| `/spend` | View API spend summary |
| `/more1` `/more5` `/more10` | Temporarily raise spend limits |
| `/prune` | Manually prune stored tool interactions to target context size |
| `/hide` / `/show` | Toggle privacy mode (hide/show UI on Mac) |
| `/transcribe_local` `/transcribe_openai` | Switch voice transcription method |

---

## 📋 Configuration Reference

All configuration is done in the app's Settings panel (⌘,), organized into four tabs. Settings auto-save as you type (0.5s debounce). See [SETUP.md](SETUP.md) for detailed instructions.

| Tab | Section | Required? | What it does |
|---|---|---|---|
| **Identity** | Persona | ✅ | Name your AI, tell it about yourself |
| **Connection** | Telegram Bot | ✅ | Bot token + your Chat ID |
| **Connection** | LLM Provider | ✅ | OpenRouter or LM Studio, model selection, reasoning effort, spend limits |
| **Services** | Voice Transcription | Optional | On-device WhisperKit or OpenAI API |
| **Services** | Web Search | Optional | Serper + Jina keys for web browsing |
| **Services** | Email | Optional | Gmail API (recommended) or IMAP/SMTP |
| **Services** | Image Generation | Optional | Gemini API key for image generation |
| **Services** | Code CLI | Optional | Choose Claude Code, Gemini CLI, or Codex CLI |
| **Services** | Vercel | Optional | Deploy projects to Vercel |
| **Services** | Instant Database | Optional | Provision and manage InstantDB databases |
| **Data** | Developer Tools | — | Context viewer, archive chunk size, context budget (max/target tokens) |
| **Data** | Data Portability | — | Mind export/import, calendar export/import, contacts, delete memory |

### LM Studio Configuration

When using LM Studio as the LLM provider:

- **Description Model** (optional) — a separate smaller model for generating file descriptions, so these calls don't evict the main model's KV cache. Configure under Connection > LM Studio.
- **Description Base URL** (optional) — if the description model runs on a different LM Studio port.
- The main model's KV cache persists indefinitely while loaded (no TTL). Manually load the model in LM Studio to prevent idle eviction (default 60min for JIT-loaded models).
- Web search and deep research always route through OpenRouter regardless of provider selection, preserving the local KV cache.

---

## 📄 License

This project is open source and available under the [MIT License](LICENSE).

---

## 🙏 Acknowledgments

- [OpenRouter](https://openrouter.ai) — unified LLM API gateway
- [WhisperKit](https://github.com/argmaxinc/WhisperKit) — on-device speech recognition
- [Serper](https://serper.dev) — Google Search API
- [Jina AI](https://jina.ai) — web content extraction
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code/overview) — agentic coding CLI by Anthropic
- [Codex CLI](https://developers.openai.com/codex/cli) — agentic coding CLI by OpenAI
