# lazyspeak.nvim

Voice-driven coding for Neovim. Speak your intent, edits appear in your editor.

## Overview

A Neovim plugin that captures voice input, transcribes it locally via Voxtral Mini 3B, and dispatches coding instructions to any ACP-compatible agent (Claude Code, Gemini CLI, Goose, Codex, etc.).

```
Mic → Voxtral Mini 3B (local STT) → transcript → adapter → agent → Neovim
         ~2.5 GB, Apache 2.0           ACP or Claude Code IDE protocol
```

No cloud STT dependency. No TTS. You speak, it codes.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│ Neovim                                                          │
│                                                                 │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │ lazyspeak.nvim (Lua)                                      │  │
│  │                                                           │  │
│  │  ┌───────────┐  ┌──────────┐  ┌────────┐  ┌───────────┐ │  │
│  │  │ voice.lua │  │ core.lua │  │ ui.lua │  │ health.lua│ │  │
│  │  │ mic ctl   │  │ IR types │  │ float  │  │ checkhealth│ │  │
│  │  └─────┬─────┘  └────┬─────┘  │ status │  └───────────┘ │  │
│  │        │              │        └────────┘                 │  │
│  │        │         ┌────┴─────────────────┐                 │  │
│  │        │         │  adapters/            │                 │  │
│  │        │         │  ┌─────────────────┐  │                │  │
│  │        │         │  │ acp.lua         │  │                │  │
│  │        │         │  │ JSON-RPC/stdio  │──┼── Gemini, Goose│  │
│  │        │         │  └─────────────────┘  │    Codex, etc. │  │
│  │        │         │  ┌─────────────────┐  │                │  │
│  │        │         │  │ claudecode.lua  │  │                │  │
│  │        │         │  │ WebSocket MCP   │──┼── Claude Code  │  │
│  │        │         │  └─────────────────┘  │                │  │
│  │        │         └──────────────────────┘                 │  │
│  └────────┼──────────────────────────────────────────────────┘  │
└───────────┼─────────────────────────────────────────────────────┘
            │ stdin/stdout JSON lines
            ▼
┌──────────────────┐
│ lazyspeak-daemon │
│ (Rust binary)    │
│ - mic capture    │
│ - VAD            │
│ - Voxtral STT   │
└────────┬─────────┘
         ▼
┌──────────────────┐
│ Voxtral Mini 3B  │
│ (llama.cpp local)│
│ Q4 GGUF ~2.5 GB  │
│ Metal accelerated│
└──────────────────┘
```

### Internal Representation (IR)

The core abstraction. All adapters translate to/from these IR types. This decouples the plugin from any specific agent protocol.

```lua
-- core.lua defines the IR

---@class lazyspeak.Request
---@field type "prompt" | "cancel"
---@field session_id string
---@field text string              -- the transcript

---@class lazyspeak.Event
---@field type "message" | "tool_call" | "diff" | "permission" | "done" | "error"
---@field session_id string
---@field text? string             -- streamed agent text
---@field tool_name? string        -- tool being called
---@field diff? lazyspeak.Diff     -- proposed file edit
---@field permission? lazyspeak.Permission -- agent asking for approval
---@field error? string

---@class lazyspeak.Diff
---@field path string              -- absolute file path
---@field old_content string
---@field new_content string

---@class lazyspeak.Permission
---@field id string
---@field description string       -- "Write to src/auth.lua"
---@field callback fun(approved: boolean)

---@class lazyspeak.Snapshot
---@field id string                -- unique snapshot id (timestamp-based)
---@field session_id string
---@field transcript string        -- what the user said
---@field timestamp number
---@field files string[]           -- files affected
---@field stash_ref string         -- git stash ref (stash@{n})
---@field undo_data table<string, string>  -- fallback: path → original content (non-git)

---@class lazyspeak.Adapter
---@field start fun(opts: table): nil
---@field stop fun(): nil
---@field send fun(req: lazyspeak.Request): nil
---@field on_event fun(callback: fun(event: lazyspeak.Event)): nil
```

Every adapter implements `lazyspeak.Adapter`. The plugin never talks protocol-specific messages — only IR types.

### Components

#### 1. `lua/lazyspeak/` — Neovim plugin (Lua)

**voice.lua** — Manages the Python STT daemon
- Spawns/stops the daemon process
- Sends commands (start/stop listening, cancel)
- Receives transcripts via stdout JSON lines

**core.lua** — IR types and adapter dispatch
- Defines `Request`, `Event`, `Diff`, `Permission` types
- Loads the configured adapter
- Routes transcripts → adapter → events → UI

**adapters/acp.lua** — ACP adapter
- Spawns the agent as a subprocess with stdio pipes
- Translates IR `Request` → ACP `session/prompt` (JSON-RPC 2.0)
- Translates ACP `session/update`, `fs/*`, `terminal/*` → IR `Event`
- Handles capability negotiation during `initialize`

**adapters/claudecode.lua** — Claude Code IDE protocol adapter
- Discovers Claude Code via `~/.claude/ide/*.lock` files
- Connects over WebSocket with auth token
- Translates IR `Request` → Claude Code stdin prompt or MCP notification
- Translates MCP tool calls (`openDiff`, `getDiagnostics`) → IR `Event`
- Can also spawn Claude Code CLI and pipe transcripts as user input

**snapshot.lua** — Pre-edit snapshots for undo/revert
- Creates a snapshot before every agent edit lands
- Git repos: `git stash create` (creates stash ref without modifying working tree state, then stores the ref)
- Non-git: reads and caches file contents in memory
- Maintains a stack of snapshots per session
- Revert = pop latest snapshot, restore files
- Voice commands "undo", "revert", "go back" are intercepted before reaching the agent

**ui.lua** — Visual feedback
- Floating window (waveform + transcript + permission prompts)
- Status line component
- Diff display for agent-proposed edits

#### 2. `crates/` — Rust daemon binary (~5 MB)

- **lazyspeak-core**: library crate — audio capture (cpal), energy-based VAD, STT HTTP client, JSON lines protocol
- **lazyspeak-cli**: binary crate — event loop wiring audio → STT → protocol over stdin/stdout
- Single static binary, no runtime dependencies

#### 3. Voxtral Mini 3B — local inference

- Runs as a persistent `llama-server` process
- Q4_K_M GGUF (~2.5 GB), Metal-accelerated on Apple Silicon
- Daemon connects via HTTP (`/v1/audio/transcriptions` or `/v1/chat/completions`)

## ACP Integration

lazyspeak.nvim implements an **ACP host** — the Neovim-side client that speaks the Agent Client Protocol. This is the same pattern as `vim.lsp` (JSON-RPC over stdio) but bidirectional.

### Lifecycle

```
1. User presses <leader>ls      → start listening
2. User speaks                   → daemon captures audio, runs VAD
3. User stops / silence detected → daemon transcribes via Voxtral
4. Transcript received           → check for voice commands (undo/revert)
   4a. If "undo"/"revert"        → pop snapshot, restore files, done
   4b. Otherwise                 → continue to step 5
5. Snapshot created              → git stash create (or cache file contents)
6. Transcript sent to adapter    → adapter translates IR → agent protocol
7. Agent streams response        → session/update notifications
8. Agent requests file edit      → adapter translates → IR Event → Neovim applies
9. Agent requests permission     → UI prompt → user approves with y/n
10. Agent done                   → snapshot kept on stack for future undo
```

### Voice Commands (intercepted before agent)

Certain transcripts are handled locally without reaching the agent:

| Phrase | Action |
|--------|--------|
| "undo", "revert", "go back", "undo that" | Pop last snapshot, restore files |
| "undo all", "revert everything" | Pop all snapshots for current session |
| "cancel", "stop", "nevermind" | Cancel current recording or agent request |

Matching is fuzzy (lowercased, trimmed, checked against patterns). Configurable via `opts.voice_commands`.

### ACP Messages (what lazyspeak sends/receives)

**lazyspeak → Agent:**
```json
{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
  "protocolVersion": "0.11.4",
  "clientInfo": {"name": "lazyspeak.nvim", "version": "0.1.0"},
  "clientCapabilities": {
    "fs": {"readTextFile": true, "writeTextFile": true},
    "terminal": {"create": true, "output": true, "waitForExit": true, "kill": true},
    "promptTypes": {"audio": false}
  }
}}

{"jsonrpc": "2.0", "id": 2, "method": "session/new", "params": {
  "cwd": "/path/to/project"
}}

{"jsonrpc": "2.0", "id": 3, "method": "session/prompt", "params": {
  "sessionId": "abc-123",
  "content": [{"type": "text", "text": "refactor the auth middleware to use JWT"}]
}}
```

**Agent → lazyspeak (callbacks):**
```json
{"jsonrpc": "2.0", "id": 10, "method": "fs/read_text_file", "params": {
  "path": "/absolute/path/to/file.lua"
}}

{"jsonrpc": "2.0", "id": 11, "method": "fs/write_text_file", "params": {
  "path": "/absolute/path/to/file.lua",
  "content": "-- updated content"
}}

{"jsonrpc": "2.0", "id": 12, "method": "session/request_permission", "params": {
  "sessionId": "abc-123",
  "toolCallId": "tc-1",
  "description": "Write to src/auth.lua"
}}
```

**Agent → lazyspeak (notifications):**
```json
{"jsonrpc": "2.0", "method": "session/update", "params": {
  "sessionId": "abc-123",
  "type": "agent_message_chunk",
  "text": "I'll refactor the auth middleware..."
}}

{"jsonrpc": "2.0", "method": "session/update", "params": {
  "sessionId": "abc-123",
  "type": "tool_call",
  "toolCallId": "tc-1",
  "name": "write_file",
  "arguments": "{\"path\": \"src/auth.lua\", ...}"
}}
```

### Agent Configuration

```lua
require("lazyspeak").setup({
  agent = {
    -- Adapter: "acp" or "claudecode"
    adapter = "claudecode",

    -- Claude Code adapter (default): connects to running Claude Code
    -- No extra config needed — auto-discovers via ~/.claude/ide/*.lock
    -- Or spawns a new Claude Code CLI if none is running.

    -- ACP adapter: spawns agent as subprocess
    -- adapter = "acp",
    -- cmd = { "gemini", "--acp" },
    -- cmd = { "goose", "session", "--acp" },
    -- cmd = { "npx", "@zed-industries/claude-code-acp" },
  },
})
```

## Interface

### Keybindings

All under `<leader>ls` prefix:

| Key | Mode | Action |
|-----|------|--------|
| `<leader>ls` | n | Push-to-talk (press to listen, press again to send) |
| `<leader>lS` | n | Toggle continuous listening (VAD auto-segments) |
| `<leader>lc` | n | Cancel current recording or agent request |
| `<leader>lh` | n | Show transcript history |
| `<leader>lu` | n | Undo last agent edit (revert snapshot) |
| `<leader>la` | n | Switch agent (`:LazySpeakAgent`) |

### Status Line

`require("lazyspeak").status()` returns:

| State | Display |
|-------|---------|
| Inactive | `""` |
| Listening | `"ls:mic"` |
| Transcribing | `"ls:..."` |
| Agent working | `"ls:>>>"` |
| Agent awaiting permission | `"ls:???"` |

### Floating Window

Bottom-right float appears during active use:

```
┌─ lazyspeak ──────────────────┐
│ ▁▂▃▅▇▅▃▂▁  listening...     │
│                              │
│ "refactor the auth           │
│  middleware to use JWT"      │
│                              │
│ [agent] Writing src/auth.lua │
│ [y/n] Allow?                 │
└──────────────────────────────┘
```

Permission requests from the agent appear inline. User approves with `y`/`n` or configures auto-approve.

### Commands

| Command | Description |
|---------|-------------|
| `:LazySpeakStart` | Start daemon + agent |
| `:LazySpeakStop` | Stop everything |
| `:LazySpeakStatus` | Show daemon/agent/model status |
| `:LazySpeakHistory` | Transcript history buffer |
| `:LazySpeakUndo` | Revert last agent edit |
| `:LazySpeakSnapshots` | List snapshots for current session |
| `:LazySpeakAgent [cmd]` | Switch ACP agent |
| `:LazySpeakInstall` | Download model + install Python deps |

## Configuration

```lua
require("lazyspeak").setup({
  -- Agent adapter
  agent = {
    adapter = "claudecode",  -- "claudecode" | "acp"
    -- For claudecode: auto-discovers or spawns Claude Code CLI
    -- For acp: spawns subprocess
    -- cmd = { "gemini", "--acp" },
    -- auto_approve = false,
  },

  -- STT model
  model = {
    path = "~/.local/share/lazyspeak/voxtral-mini-3b-q4_k_m.gguf",
    server_port = 8674,
    -- or connect to existing server:
    -- server_url = "http://127.0.0.1:8080",
  },

  -- Audio capture
  audio = {
    sample_rate = 16000,
    channels = 1,
    vad_threshold = 0.5,
    silence_duration_ms = 1000,
    max_duration_ms = 30000,
  },

  -- UI
  ui = {
    float_position = "bottom-right",
    float_width = 40,
    show_waveform = true,
    statusline = true,
  },

  -- Snapshots
  snapshot = {
    enabled = true,
    max_stack = 20,        -- max snapshots per session
    use_git = true,        -- prefer git stash (falls back to in-memory)
  },

  -- Keybindings
  keys = {
    push_to_talk = "<leader>ls",
    toggle_listen = "<leader>lS",
    cancel = "<leader>lc",
    history = "<leader>lh",
    undo = "<leader>lu",
    switch_agent = "<leader>la",
  },
})
```

## Daemon Protocol

Plugin ↔ Python daemon over stdin/stdout JSON lines.

### Plugin → Daemon (stdin)

```jsonl
{"cmd": "start_listening"}
{"cmd": "stop_listening"}
{"cmd": "cancel"}
{"cmd": "shutdown"}
```

### Daemon → Plugin (stdout)

```jsonl
{"type": "status", "state": "listening"}
{"type": "status", "state": "transcribing"}
{"type": "status", "state": "idle"}
{"type": "vad", "speaking": true}
{"type": "vad", "speaking": false}
{"type": "transcript", "text": "refactor the auth middleware to use JWT", "duration_ms": 3200}
{"type": "error", "message": "mic not available"}
```

## Dependencies

### Required

| Dependency | Purpose | Size | License |
|---|---|---|---|
| `lazyspeak` binary (Rust) | Mic capture, VAD, STT dispatch | ~5 MB | Apache 2.0 |
| Voxtral Mini 3B Q4 GGUF | Speech-to-text model | ~2.5 GB | Apache 2.0 |
| `llama-server` (llama.cpp) | Local model inference server | ~50 MB | MIT |
| An ACP agent or Claude CLI | Coding intelligence | varies | varies |

### Rust crates (compiled into binary)

| Crate | Purpose | License |
|---|---|---|
| `cpal` | Cross-platform audio capture | Apache 2.0 |
| `reqwest` | HTTP client for STT server | MIT/Apache 2.0 |
| `hound` | WAV encoding | Apache 2.0 |
| `serde`/`serde_json` | JSON protocol | MIT/Apache 2.0 |

### Total local footprint: ~2.5 GB (dominated by the model)

## Installation

### 1. Plugin (lazy.nvim)

```lua
{
  "urmzd/lazyspeak.nvim",
  build = ":LazySpeakInstall",
  opts = {
    agent = { adapter = "claudecode" },
  },
}
```

### 2. `:LazySpeakInstall` automates:

- Downloads Voxtral GGUF model (~2.5 GB) to `~/.local/share/lazyspeak/`
- Builds and installs the `lazyspeak` daemon binary via `cargo install`

### 3. Manual install (alternative)

```sh
# Build daemon
cargo install --path crates/lazyspeak-cli

# Download model
just download-model
```

## File Structure

```
lazyspeak.nvim/
├── Cargo.toml                -- workspace root
├── Justfile                  -- dev tasks
├── crates/
│   ├── lazyspeak-core/       -- library: audio, protocol, transcribe
│   │   └── src/
│   │       ├── lib.rs
│   │       ├── audio.rs      -- cpal mic capture + energy VAD
│   │       ├── protocol.rs   -- JSON lines Command/Event types
│   │       └── transcribe.rs -- HTTP STT client (llama-server)
│   └── lazyspeak-cli/        -- binary: daemon entry point
│       └── src/
│           └── main.rs       -- event loop wiring audio → STT → protocol
├── lua/
│   └── lazyspeak/
│       ├── init.lua          -- setup(), public API, keybindings
│       ├── voice.lua         -- spawn/manage Rust daemon (jobstart)
│       ├── core.lua          -- IR types, voice command interception, adapter dispatch
│       ├── snapshot.lua      -- git stash snapshots, undo/revert
│       ├── install.lua       -- :LazySpeakInstall (model download + cargo build)
│       ├── adapters/
│       │   ├── acp.lua       -- ACP adapter (JSON-RPC 2.0 / stdio)
│       │   └── claudecode.lua -- Claude Code adapter (CLI pipe)
│       ├── ui.lua            -- floating window, statusline
│       └── health.lua        -- :checkhealth lazyspeak
├── plugin/
│   └── lazyspeak.vim         -- command definitions
├── SPEC.md
├── LICENSE                   -- Apache 2.0
└── .gitignore
```

## Future Extensions

- **Silero VAD** — replace energy-based VAD with ONNX silero-vad model for better accuracy
- **Context injection** — automatically include current file, selection, and diagnostics with transcript
- **Wake word** — optional activation without keybind
- **Voice feedback** — optional TTS via Piper (MIT) or Voxtral TTS API
- **Claude Code WebSocket** — upgrade claudecode adapter from CLI pipe to IDE protocol
- **ACP agent registry** — browse/install agents from JetBrains ACP registry
- **Multi-session** — multiple concurrent agent sessions
- **Pre-built binaries** — GitHub releases with binaries for macOS/Linux (ARM + x86)
