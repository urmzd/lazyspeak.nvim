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
│  │  ┌───────────┐  ┌──────────┐  ┌───────────┐ ┌──────────┐│  │
│  │  │ voice.lua │  │ core.lua │  │sidebar.lua│ │health.lua││  │
│  │  │ mic ctl   │  │ IR types │  │ status +  │ │checkhealth│  │
│  │  └─────┬─────┘  └────┬─────┘  │conversation│└──────────┘│  │
│  │        │              │        ├───────────┤             │  │
│  │        │              │        │  ui.lua   │             │  │
│  │        │              │        │ statusline│             │  │
│  │        │              │        └───────────┘             │  │
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

**voice.lua** — Manages the Rust STT daemon
- Spawns/stops the daemon process
- Sends commands (start/stop listening, cancel)
- Receives interim (`partial`) and final transcripts via stdout JSON lines

**core.lua** — IR types and adapter dispatch
- Defines `Request`, `Event`, `Diff`, `Permission` types
- Loads the configured adapter
- Routes transcripts → adapter → events → UI

**adapters/acp.lua** — ACP adapter
- Spawns the agent as a subprocess with stdio pipes
- Translates IR `Request` → ACP `session/prompt` (JSON-RPC 2.0)
- Translates ACP `session/update`, `fs/*`, `terminal/*` → IR `Event`
- Handles capability negotiation during `initialize`

**adapters/claudecode.lua** — Claude Code preset over the ACP adapter
- Thin wrapper that defaults `agent.cmd` to the official Claude ACP bridge
  (`npx -y @agentclientprotocol/claude-agent-acp`), then delegates to `acp.lua`
- All protocol work (streaming, tool calls, permissions, fs edits) goes through
  the single ACP code path — no bespoke Claude logic
- Auth is inherited from the environment (`ANTHROPIC_API_KEY` or `claude login`)

**snapshot.lua** — Pre-turn snapshots for undo/revert
- Stored **outside the repository**, at
  `$XDG_STATE_HOME/nvim/lazyspeak/snapshots/<session>/<snapshot>/`. Writing
  through `git stash store` put plugin bookkeeping into the user's own stash
  list, where it accumulated and mixed with their real stashes. `stdpath("state")`
  because this is regenerable session state, and where Neovim keeps undo/swap/shada
- Captures tracked files differing from HEAD, copied with `vim.uv.fs_copyfile`
  so trailing newlines and binary content round-trip byte-exactly
- Revert restores captured files, and returns to HEAD any file the agent dirtied
  that was clean at snapshot time. Agent-created files are left in place
- A turn that changes nothing discards its snapshot, guarded by a content
  fingerprint of `git diff HEAD` (porcelain names which files differ, not how,
  so it missed edits to already-modified files)
- Eviction past `max_stack`, `:LazySpeakStop`, and exit all delete stored copies;
  startup sweeps session dirs older than `max_age_days`
- Requires a git repository: without it there is no cheap way to know which
  files a turn might touch
- `orphans`/`prune_orphans` remain to migrate users off the old stash entries
- Voice commands "undo", "revert", "go back" are intercepted before reaching the agent

**sidebar.lua** — The single in-editor surface
- Right-hand vertical split, full height
- Fixed 4-row header: process signals (stt/daemon/agent), current phase,
  state-aware key hints, and a rule
- Conversation below, held as a list of typed entries rather than raw text
- Entry kinds: turn, partial, message, thought, tool, permission, error, note
- Each entry renders its own frame; streaming re-renders only the entry it
  touches; a resize re-flows everything from the model
- Hard-wrapped to window width with `wrap` off, so borders stay aligned
- Key reference shown as the empty state, toggled thereafter with `?`
- Highlights link to standard groups so the sidebar follows the colorscheme

**ui.lua** — Status line component only
- Compact state string for lualine and friends

#### 2. `crates/` — Rust daemon binary (~5 MB)

- **lazyspeak**: single crate (lib + binary) — audio capture (cpal), energy-based VAD, STT HTTP client, JSON lines protocol, event loop wiring audio → STT → protocol over stdin/stdout
- A failed transcription emits `Event::Error`, never a `Transcript` carrying
  placeholder text. Fabricated transcripts were snapshotted and sent to the
  agent as if the user had said them
- Single static binary, no runtime dependencies

#### 3. Voxtral Mini 3B — local inference

- Runs as a persistent `llama-server` process
- Q4_K_M GGUF (~2.5 GB), Metal-accelerated on Apple Silicon
- Daemon connects via HTTP (`/v1/audio/transcriptions` or `/v1/chat/completions`)

## ACP Integration

lazyspeak.nvim implements an **ACP host** — the Neovim-side client that speaks the Agent Client Protocol. This is the same pattern as `vim.lsp` (JSON-RPC over stdio) but bidirectional.

### Lifecycle

```
1. User presses <leader>ls      → open session, start daemon if needed
1a. User presses <Space>         → start listening
2. User speaks                   → daemon captures audio, runs VAD
3. User stops / silence detected → daemon transcribes via Voxtral
4. Transcript received           → check for voice commands (undo/revert)
   4a. If "undo"/"revert"        → pop snapshot, restore files, done
   4b. Otherwise                 → continue to step 5
5. Snapshot created              → git stash create (or cache file contents)
6. Transcript sent to adapter    → adapter translates IR → agent protocol
7. Agent streams response        → session/update notifications → sidebar
8. Agent requests file edit      → adapter translates → IR Event → Neovim applies
9. Agent requests permission     → vim.ui.select; sidebar records the ask
10. Agent done                   → snapshot kept on stack for future undo
```

### What context reaches the agent

Deliberately minimal today:

| Sent | When |
|------|------|
| `cwd` (`vim.fn.getcwd()`) | once, in `session/new` |
| Transcript as a single `text` content block | every `session/prompt` |

The client advertises `fs.readTextFile` and `fs.writeTextFile`, so the agent can
read and edit anything under `cwd` on its own initiative — but it is never told
the active buffer, cursor position, visual selection, or any buffer contents.

Consequence: deictic prompts ("this function", "the line I'm on") cannot work.
Automatic context injection is unimplemented; ACP's `resource_link` and
`resource` content blocks are the intended vehicle when it lands.

### Voice Commands (intercepted before agent)

Certain transcripts are handled locally without reaching the agent:

| Phrase | Action |
|--------|--------|
| "undo", "revert", "go back", "undo that" | Pop last snapshot, restore files |
| "undo all", "revert everything" | Pop all snapshots for current session |
| "cancel", "stop", "nevermind" | Cancel current recording or agent request |

Matching is fuzzy (lowercased, trimmed, checked against patterns). Configurable via `opts.voice_commands`.

### ACP Messages (what lazyspeak sends/receives)

These follow the stable ACP v1 wire format (`protocolVersion: 1`). There is no
`initialized` handshake — after the `initialize` response the client proceeds
straight to `session/new`.

**lazyspeak → Agent:**
```json
{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
  "protocolVersion": 1,
  "clientCapabilities": {
    "fs": {"readTextFile": true, "writeTextFile": true},
    "terminal": false
  }
}}

{"jsonrpc": "2.0", "id": 2, "method": "session/new", "params": {
  "cwd": "/path/to/project",
  "mcpServers": []
}}

{"jsonrpc": "2.0", "id": 3, "method": "session/prompt", "params": {
  "sessionId": "abc-123",
  "prompt": [{"type": "text", "text": "refactor the auth middleware to use JWT"}]
}}
```

The `initialize` response carries `agentCapabilities.promptCapabilities`
(`{image, audio, embeddedContext}`). Claude advertises no `audio`, so lazyspeak
always sends a `text` content block; an audio-capable agent (e.g. Gemini) could
receive an `audio` block instead.

**Agent → lazyspeak (requests, expect a response):**
```json
{"jsonrpc": "2.0", "id": 10, "method": "fs/read_text_file", "params": {
  "path": "/absolute/path/to/file.lua"
}}
// → result: {"content": "..."}

{"jsonrpc": "2.0", "id": 11, "method": "fs/write_text_file", "params": {
  "path": "/absolute/path/to/file.lua",
  "content": "-- updated content"
}}
// → result: {}

{"jsonrpc": "2.0", "id": 12, "method": "session/request_permission", "params": {
  "sessionId": "abc-123",
  "toolCall": {"toolCallId": "tc-1", "title": "Write to src/auth.lua", "kind": "edit", "status": "pending"},
  "options": [
    {"optionId": "allow", "name": "Allow", "kind": "allow_once"},
    {"optionId": "reject", "name": "Reject", "kind": "reject_once"}
  ]
}}
// → result: {"outcome": {"outcome": "selected", "optionId": "allow"}}
//   (or {"outcome": {"outcome": "cancelled"}})
```

**Agent → lazyspeak (notifications, no response):**
```json
{"jsonrpc": "2.0", "method": "session/update", "params": {
  "sessionId": "abc-123",
  "update": {
    "sessionUpdate": "agent_message_chunk",
    "content": {"type": "text", "text": "I'll refactor the auth middleware..."}
  }
}}

{"jsonrpc": "2.0", "method": "session/update", "params": {
  "sessionId": "abc-123",
  "update": {
    "sessionUpdate": "tool_call",
    "toolCallId": "tc-1",
    "title": "Write file",
    "kind": "edit",
    "status": "pending",
    "rawInput": {"path": "src/auth.lua"}
  }
}}
```

The `session/prompt` response (not a notification) carries the turn's
`stopReason` (`end_turn`, `max_tokens`, `cancelled`, `refusal`).

### Agent Configuration

```lua
require("lazyspeak").setup({
  agent = {
    -- Adapter: "claudecode" (default) or "acp"
    adapter = "claudecode",

    -- claudecode: launches the official Claude ACP bridge via npx
    --   (npx -y @agentclientprotocol/claude-agent-acp). Auth via
    --   ANTHROPIC_API_KEY env or a prior `claude login`.

    -- acp: spawn any ACP agent as a subprocess
    -- adapter = "acp",
    -- cmd = { "gemini", "--acp" },
    -- cmd = { "goose", "acp" },
    -- cmd = { "claude-agent-acp" },  -- bridge installed globally

    -- false = prompt on every permission request; true = auto-allow
    auto_approve = false,
  },
})
```

## Interface

### Keybindings

Implemented:

| Key | Mode | Action |
|-----|------|--------|
| `<leader>ls` | n | Open the session (starts the daemon if needed) |
| `<Space>` | n | Start/stop recording while the session is open |
| `<Esc>` | n | Cancel recording and dismiss the UI |
| `<leader>lc` | n | Cancel current recording or agent request |
| `<leader>lu` | n | Undo last agent edit (revert snapshot) |
| `<leader>ll` | n | Toggle the session sidebar |

Reserved in `defaults.keys` but not yet bound: `toggle_listen` (`<leader>lS`),
`history` (`<leader>lh`), `switch_agent` (`<leader>la`).

### Status Line

`require("lazyspeak").status()` returns:

| State | Display |
|-------|---------|
| Inactive | `""` |
| Listening | `"ls:mic"` |
| Transcribing | `"ls:..."` |
| Agent working | `"ls:>>>"` |
| Agent awaiting permission | `"ls:???"` |

### The Sidebar

One surface holds everything: a right-hand vertical split, full height. A fixed
4-row header answers "is anything wrong, and what do I press?" while the
conversation below answers
"what did it do?".

```
 ● stt  ● daemon  ◐ agent
 ⠹ agent working...
 <leader>lc interrupt   ? help
────────────────────────────────────────────────
╭─ you ──────────────────────────────── 22:30 ─╮
│ refactor the auth middleware to use JWT      │
╰──────────────────────────────────────────────╯

⏺ thinking
  The current check reads a session cookie.

⏺ agent
  I will switch the session check to a JWT
  verify and keep the same error shape.

⏺ Read(lua/auth/middleware.lua)
  ⎿ ✓ completed

⏺ Edit(lua/auth/middleware.lua)
  ⎿ ◐ pending

⏺ ? Edit middleware.lua?
  ⎿ allow once
```

**Header.** Three process signals (`○` down, `◐` starting, `●` up, `✗` failed),
the current phase with a spinner while work is in flight, and hints for the keys
that are useful in that state. The header is a constant row count rewritten in
place, so status ticks never disturb entry offsets below it.

Hints list only globally-bound maps, so a hint is never shown for something that
would not work from wherever the cursor is. `?` and `q` are local to the sidebar
window and are labelled as such in the reference block.

**Discovery.** The key reference occupies the conversation region until the first
entry arrives, then gives way to it. `?` (or `:LazySpeakHelp`) brings it back
above the conversation without disturbing the entries.

**Conversation.** Held as a list of typed entries, not appended text. That is
what makes per-entry framing, cheap streaming, and resize re-flow possible:
streaming mutates one entry's text and re-renders only its row range, while a
width change re-renders every entry from the model.

Content is hard-wrapped to the window width and `wrap` is off. Soft wrapping
would break box borders and gutters, so the renderer owns every line.

Permission requests are driven by `vim.ui.select`; the sidebar records both the
ask and the resolution as a single entry.

### Lifetimes

| Action | Sidebar window | Conversation buffer | Daemon |
|--------|---------------|--------------------|--------|
| `<Esc>` / `:LazySpeakDismiss` | closed | kept | running |
| `:LazySpeakStop` | closed | deleted | stopped |
| Exit Neovim (`VimLeavePre`) | closed | deleted | stopped |

Shutdown is wired to `VimLeavePre`, so quitting never strands the daemon,
`llama-server`, or the agent process.

### Commands

| Command | Description |
|---------|-------------|
| `:LazySpeakStart` | Start daemon + agent |
| `:LazySpeakStop` | Stop everything and tear down the UI |
| `:LazySpeakStatus` | Show daemon/agent/model status |
| `:LazySpeakSidebar` | Toggle the session sidebar |
| `:LazySpeakHelp` | Toggle the key reference in the sidebar |
| `:LazySpeakDismiss` | Hide the sidebar, leave the daemon running |
| `:LazySpeakUndo` | Revert last agent edit |
| `:LazySpeakSnapshots` | List snapshots for current session |
| `:LazySpeakSnapshotsPrune` | Drop orphaned `lazyspeak:` stash entries |
| `:LazySpeakInstall` | Build and install the daemon binary |

Planned, not yet implemented: `:LazySpeakHistory`, `:LazySpeakAgent [cmd]`.

## Configuration

```lua
require("lazyspeak").setup({
  -- Agent adapter
  agent = {
    adapter = "claudecode",  -- "claudecode" | "acp"
    -- claudecode: launches npx -y @agentclientprotocol/claude-agent-acp
    -- acp: spawns the given command
    -- cmd = { "gemini", "--acp" },
    auto_approve = false,    -- true to auto-allow agent permission requests
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
    vad_threshold = 0.01,
    silence_duration_ms = 400,     -- trailing silence before finalizing (latency knob)
    max_duration_ms = 30000,
    partial_interval_ms = 700,     -- interim transcript cadence (0 disables)
  },

  -- UI
  ui = {
    sidebar_position = "right",   -- "right" | "left"
    sidebar_width = 48,
    sidebar_auto_open = true,     -- open the sidebar when a session starts
    statusline = true
  },

  -- Snapshots
  snapshot = {
    enabled = true,
    max_stack = 20,        -- max snapshots per session
    max_age_days = 7,      -- sweep sessions left by a crash
  },

  -- Keybindings
  keys = {
    push_to_talk = "<leader>ls",
    cancel = "<leader>lc",
    undo = "<leader>lu",
    sidebar = "<leader>ll",
    -- Reserved, not yet bound:
    -- toggle_listen = "<leader>lS",
    -- history = "<leader>lh",
    -- switch_agent = "<leader>la",
  },
})
```

## Daemon Protocol

Plugin ↔ Rust daemon over stdin/stdout JSON lines.

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
{"type": "partial", "text": "refactor the auth"}
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
cargo install --path crates/lazyspeak

# Download model
just download-model
```

## File Structure

```
lazyspeak.nvim/
├── Cargo.toml                -- workspace root
├── Justfile                  -- dev tasks
├── crates/
│   └── lazyspeak/            -- lib + binary
│       └── src/
│           ├── lib.rs        -- public modules: audio, protocol, transcribe, pipeline
│           ├── main.rs       -- daemon entry point, event loop
│           ├── audio.rs      -- cpal mic capture + energy VAD
│           ├── protocol.rs   -- JSON lines Command/Event types
│           ├── transcribe/   -- STT backends
│           └── pipeline/     -- streamsafe pipeline stages
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
│       ├── sidebar.lua       -- status header + conversation
│       ├── ui.lua            -- statusline component
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
- **Native-audio fast path** — forward raw audio blocks to audio-capable ACP agents (e.g. Gemini), skipping local STT
- **ACP agent registry** — browse/install agents from JetBrains ACP registry
- **Multi-session** — multiple concurrent agent sessions
- **Pre-built binaries** — GitHub releases with binaries for macOS/Linux (ARM + x86)
