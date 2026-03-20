# Engram

A native macOS AI agent with holographic memory. Written in Swift.

Engram remembers things the way brains do — not in a database, not in a vector store, but in superposed complex vectors that encode facts as interference patterns. Recall is algebraic and sub-millisecond. No embeddings API. No retrieval pipeline. Just math.

---

| | |
|---|---|
| **Holographic memory** | Facts stored as bound key-value pairs in complex vector space. Frequently recalled facts promote into permanent context. |
| **Native macOS** | Calendar, Contacts, Spotlight, Clipboard, TTS, Safari automation. No Electron. No Docker. Just your Mac. |
| **Multi-provider** | Anthropic, OpenAI, OpenRouter, Ollama, Groq, Together, Mistral, xAI, DeepSeek, Cerebras. Swap with one command. |
| **Messaging gateway** | iMessage, Telegram, Discord, Slack, Email, Home Assistant. Same agent, every platform. |
| **Skills** | Markdown instruction files the agent loads on demand. Create your own or install from GitHub. |
| **Daemon mode** | Runs as a LaunchAgent. Polls gateways, fires cron jobs, consolidates memory. Survives reboots. |

## Install

```sh
git clone https://github.com/anthropics/engram.git
cd engram
swift build -c release
cp .build/release/engram /usr/local/bin/
```

Requires macOS 14+ and Swift 5.9+.

## Get started

```sh
# First run — authenticate and pick a model
engram setup

# Or set your key directly
export ANTHROPIC_API_KEY="sk-ant-..."
engram chat

# One-shot mode
engram chat "What's on my calendar today?"

# Switch models
engram model

# OAuth login (uses your Claude Pro/Team subscription)
engram login
```

On first conversation, Engram asks your name, learns how you work, and builds context from there. It never announces that it's remembering. It just knows.

## CLI

```
engram chat              Interactive session (default)
engram chat "prompt"     One-shot — answer and exit
engram setup             Configure provider, model, API key
engram login             OAuth login (Anthropic or OpenAI)
engram model             Browse and select models
engram skills            Manage skills
engram gateway           Configure messaging platforms
engram daemon install    Install as background service
engram daemon start      Start the daemon
engram daemon status     Check daemon health
engram daemon logs       Tail daemon output
```

### Slash commands (in chat)

```
/memory       View memory status across all nuggets
/skills       List available skills
/new          Clear history, start fresh session
/tokens       Show token usage for this session
/cost         Estimate session cost
/context      Show context window utilization
/help         Command reference
/exit         Quit
```

## Memory

Engram uses [Holographic Reduced Representations](https://en.wikipedia.org/wiki/Holographic_Reduced_Representation) — a model from cognitive science where information is encoded by binding key-value pairs into complex vectors and superposing them.

```
remember("favorite_color", "black")
→ keyVec("favorite_color") ⊛ valVec("black") added to memory

recall("favorite color")
→ unbind(memory, keyVec("favorite_color")) → cosine match → "black"
```

Facts live in **nuggets** — topic-scoped memories like `preferences`, `project`, `people`. The agent creates and organizes these automatically.

Facts recalled 3+ times across sessions **promote** into the system prompt as permanent context. The agent learns what matters by what it reaches for.

All memory is local. Stored as JSON in `~/.engram/memory/`.

## Tools

| Category | Tools |
|---|---|
| **Memory** | `memory_remember`, `memory_recall`, `memory_forget`, `memory_status` |
| **Files** | `file_read`, `file_write`, `file_search`, `edit`, `grep` |
| **Shell** | `terminal`, `execute_code` (Python/JS/Bash sandboxed) |
| **Web** | `web_fetch`, `web_search` (DuckDuckGo, no API key) |
| **Vision** | `vision` (image analysis), `browser` (Safari automation + screenshots) |
| **macOS** | `calendar`, `contacts`, `spotlight`, `clipboard`, `tts` |
| **Skills** | `skill_list`, `skill_view`, `skill_create` |
| **Scheduling** | `cron_create`, `cron_list`, `cron_delete` |
| **Comms** | `send_message` (gateway platforms), `delegate` (spawn sub-agent) |
| **Search** | `session_search` (FTS5 across all past conversations) |
| **Generate** | `image_gen` (DALL-E 3, requires OpenAI key) |

## Identity

Three files in `~/.engram/` define who the agent is:

| File | Purpose |
|---|---|
| `SOUL.md` | Name, personality, behavior. Updated when the user renames or adjusts the agent. |
| `USER.md` | What the agent knows about you — name, timezone, preferences, projects. Built over time. |
| `BOOTSTRAP.md` | First-run instructions. Deleted once the agent knows who it's talking to. |

These are plain markdown. Edit them directly or let the agent maintain them.

## Gateway

Run the agent as a daemon and talk to it from anywhere:

```sh
# Configure platforms
engram gateway

# Install and start the daemon
engram daemon install
engram daemon start
```

| Platform | Auth | Notes |
|---|---|---|
| **iMessage** | None (local) | Reads chat.db, sends via AppleScript. Requires Full Disk Access. |
| **Telegram** | Bot token | Long-polling. File upload support. |
| **Discord** | Bot token | WebSocket gateway. Heartbeat + message events. |
| **Slack** | App token + Bot token | Socket Mode. Channel allowlist. |
| **Email** | IMAP + SMTP | Polls for unseen messages. curl-based, no dependencies. |
| **Home Assistant** | API token | REST + persistent notifications. Service calls for automations. |

## Skills

Skills are markdown files with YAML frontmatter. The agent loads them on demand or auto-injects them into every prompt.

```
~/.engram/skills/
  my-skill/
    SKILL.md          ← instructions (required)
    references/       ← supporting docs
    templates/        ← output templates
```

Install from GitHub:

```sh
engram skills install user/repo
engram skills install user/repo#subdirectory
```

The agent can also create skills at runtime — it extends its own capabilities as it works.

## Providers

| Provider | Auth | Models |
|---|---|---|
| Anthropic | API key or OAuth | Claude Opus, Sonnet, Haiku |
| OpenAI | API key or OAuth | GPT-4o, o3 |
| OpenRouter | API key | Hundreds of models |
| Ollama | None (local) | Llama, Mistral, Qwen, etc. |
| Groq | API key | Fast inference |
| Together | API key | Open models |
| Mistral | API key | Mistral models |
| xAI | API key | Grok |
| DeepSeek | API key | DeepSeek models |
| Cerebras | API key | Fast inference |

## Configuration

Everything lives in `~/.engram/`:

```
~/.engram/
  config.json         ← model, provider, endpoints, MCP servers
  .env                ← API keys (0600 permissions)
  SOUL.md             ← agent identity
  USER.md             ← user profile
  BOOTSTRAP.md        ← first-run behavior
  memory/             ← nugget JSON files
  sessions/           ← conversation JSONL files
  skills/             ← installed skills
  cron/               ← scheduled jobs
```

## MCP

Engram supports the [Model Context Protocol](https://modelcontextprotocol.io/) for external tool servers:

```json
{
  "mcpServers": {
    "filesystem": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "/path"]
    }
  }
}
```

MCP tools are discovered at startup and available alongside built-in tools.

## Architecture

```
CLI ──→ AgentLoop ──→ LLMClient ──→ Anthropic / OpenAI / Codex
           │
           ├── ToolRegistry ──→ 30+ built-in tools
           │                     ├── MemoryTools → Shelf → Nuggets (HRR)
           │                     ├── FileTools, EditTool, GrepTool
           │                     ├── TerminalTool, ExecuteCodeTool
           │                     ├── macOS tools (Calendar, Contacts, etc.)
           │                     └── MCPToolWrapper → external servers
           │
           ├── ContextManager ──→ token tracking, auto-compaction
           ├── SessionManager ──→ JSONL persistence, tree-based branching
           ├── SkillLoader ──→ markdown skill discovery
           └── CronScheduler ──→ tick-based job execution

Daemon ──→ AgentLoop (shared)
  ├── Gateway polling (iMessage, Telegram, Discord, Slack, Email, HA)
  ├── Cron tick (every 60s)
  └── Memory consolidation (every 6h)
```

## License

MIT
