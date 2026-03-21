# Engram

A native macOS AI agent with holographic memory. Single binary. Zero dependencies.

14K lines of Swift. Not a wrapper around Python or Node — built on Apple frameworks from the ground up.

---

| | |
|---|---|
| **Holographic memory** | Facts stored as bound key-value pairs in complex vector space ([HRR](https://ieeexplore.ieee.org/document/377968)). Sub-millisecond recall. No embeddings server, no vector DB. |
| **Apple-native persistence** | SwiftData for structured data, SearchKit for full-text search, Keychain for credentials. Zero raw SQL. |
| **28 tools** | Memory, files, shell, web, calendar, contacts, vision, browser, TTS, STT, code execution, MCP, skills, cron, delegation. |
| **Messaging gateway** | iMessage (with typing indicators, read receipts, tapback reactions via IMCore), Telegram, Discord, Slack, Email, Home Assistant. |
| **Prompt caching** | System prompt cached per session. 2-3s response times on subsequent messages. |
| **Parallel tool execution** | Multiple tool calls run concurrently via TaskGroup. |
| **Daemon mode** | LaunchAgent with auto-restart, kqueue-based message detection (250ms latency), memory consolidation. |

## Install

Requires macOS 14+ and Xcode.

```sh
curl -fsSL https://raw.githubusercontent.com/philadelphiaappliedintelligence/engram/main/install.sh | sh
```

Or build manually:

```sh
git clone https://github.com/philadelphiaappliedintelligence/engram.git
cd engram
swift build -c release
sudo cp .build/release/engram /usr/local/bin/
```

## Get started

```sh
engram login                     # OAuth (Anthropic or OpenAI)
engram                           # Start chatting
engram "What's on my calendar?"  # One-shot mode
engram model                     # Switch models
```

## CLI

```
engram                   Interactive chat (default)
engram "prompt"          One-shot — answer and exit
engram login             OAuth login (Anthropic or OpenAI)
engram setup             Configure provider, model, API key
engram model             Browse and select models
engram identity          View/edit identity documents
engram memory            View holographic memory
engram sessions          List past sessions
engram skills            Manage skills
engram gateway           Configure messaging platforms
engram daemon install    Install as background service
engram daemon start      Start the daemon
engram daemon status     Check daemon health
engram update            Self-update from GitHub
```

### Slash commands (in chat)

```
/memory       View memory across all artifacts
/skills       List available skills
/new          Clear history, start fresh session
/tokens       Show token usage
/context      Show context window utilization
/help         Command reference
```

## Memory

Holographic Reduced Representations (HRR) — facts encoded as interference patterns in complex vector space. Recall is algebraic and sub-millisecond.

```
remember("favorite_color", "black")
→ keyVec ⊛ valVec added to memory

recall("favorite color")
→ unbind → cosine match → "black" (0.3ms)
```

Facts live in **artifacts** — topic-scoped memories (`preferences`, `project`, `people`). The agent organizes these automatically.

Facts recalled 3+ times **promote** into the system prompt as permanent context. The agent learns what matters by what it reaches for.

## Data Layer

| Data | Framework |
|------|-----------|
| Structured data | SwiftData (`@Model`, `@ModelActor`) |
| Full-text search | SearchKit (`SKIndex`) |
| Credentials | Keychain Services + file fallback |
| Skills | Filesystem (markdown) |
| MCP | JSON-RPC stdio |

Models: Identity, Config, MemoryFact, ChatSession, ChatMessage, CronJob, Gateway, MCPServer, SkillIndex.

## Tools

| Category | Tools |
|---|---|
| **Memory** | `memory_remember`, `memory_recall`, `memory_forget`, `memory_status` |
| **Identity** | `identity_read`, `identity_edit` |
| **Files** | `file_read`, `file_write`, `file_search`, `edit`, `grep` |
| **Shell** | `terminal`, `execute_code` (Python/Bash) |
| **Web** | `web_fetch`, `web_search`, `browser` (Safari automation) |
| **macOS** | `calendar`, `contacts`, `spotlight`, `clipboard` |
| **Audio** | `tts` (text-to-speech), `transcribe_audio` (Speech.framework STT) |
| **Vision** | `vision` (image analysis) |
| **Skills** | `skill_list`, `skill_view`, `skill_create` |
| **Scheduling** | `cron_create`, `cron_list`, `cron_delete` |
| **Comms** | `send_message`, `delegate` (sub-agent) |
| **Search** | `session_search` (SearchKit FTS) |
| **Generate** | `image_gen` (DALL-E) |

Tool approval: In CLI mode, dangerous tools (`terminal`, `file_write`, `edit`, `execute_code`) prompt for confirmation before executing.

## Identity

Three identity documents stored in SwiftData, editable via CLI or agent tools:

| Key | Purpose |
|---|---|
| `soul` | Name, personality, behavior |
| `user` | What the agent knows about you — built over time |
| `bootstrap` | First-run instructions — deleted once the agent knows you |

```sh
engram identity soul    # Open in $EDITOR
engram identity         # List all
```

## Gateway

```sh
engram gateway           # Configure platforms
engram daemon install    # Install LaunchAgent
engram daemon start      # Start background service
```

| Platform | Notes |
|---|---|
| **iMessage** | kqueue file watcher on chat.db (250ms). IMCore bridge for typing/read/tapback (SIP disabled). Allowlist support. |
| **Telegram** | Long-polling. File upload. |
| **Discord** | WebSocket gateway. |
| **Slack** | Socket Mode. |
| **Email** | IMAP + SMTP. curl-based. |
| **Home Assistant** | REST API + notifications. |

### iMessage config

```json
{
  "gateway": {
    "imessage": {
      "enabled": true,
      "allowedHandles": ["+15551234567"],
      "enableIMCore": true
    }
  },
  "gatewayModel": "claude-sonnet-4-6"
}
```

## Architecture

```
CLI / Daemon
  └── AgentLoop (actor)
        ├── LLMClient ──→ Anthropic / OpenAI (streaming, prompt caching)
        ├── ToolRegistry ──→ 28 tools (parallel execution, approval workflow)
        │     ├── MemoryTools → Shelf → Artifacts (HRR vectors)
        │     ├── IdentityTools → EngramStore (SwiftData)
        │     ├── FileTools, TerminalTool, ExecuteCodeTool
        │     ├── macOS native (Calendar, Contacts, Spotlight, TTS, STT)
        │     └── MCPToolWrapper → external JSON-RPC servers
        ├── ContextManager ──→ token tracking, auto-compaction
        ├── SessionManager ──→ SwiftData + SearchKit FTS
        └── SkillLoader ──→ markdown skill discovery

Daemon (LaunchAgent)
  ├── Gateway platforms (kqueue watcher for iMessage, polling for others)
  ├── IMCore bridge (ObjC dylib injection for typing/read/tapback)
  ├── Cron scheduler (tick-based)
  └── Memory consolidation (every 6h)
```

## License

MIT
