# lazyspeak.nvim

Voice-driven coding for Neovim. Speak your intent, edits appear in your editor.

<p align="center">
  <img src="showcase/lazyspeak-demo.gif" alt="lazyspeak.nvim demo" width="600">
</p>

```
Mic -> Voxtral Mini 3B (local STT) -> transcript -> adapter -> agent -> Neovim
         ~3.2 GB GGUF, Apache 2.0      ACP or Claude Code IDE protocol
```

No cloud STT dependency. No TTS. You speak, it codes.

## Prerequisites

| Tool | Purpose | Install |
|------|---------|---------|
| Neovim >= 0.10 | Editor | [neovim.io](https://neovim.io) |
| Rust toolchain | Build daemon binary | `curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \| sh` |
| llama.cpp | Local STT inference | `brew install llama.cpp` |
| An ACP agent **or** Claude Code | Coding intelligence | See [Agent Setup](#agent-setup) |

Optional: [just](https://github.com/casey/just) for convenient dev commands.

## Installation

### With [lazy.nvim](https://github.com/folke/lazy.nvim) (recommended)

```lua
{
  "urmzd/lazyspeak.nvim",
  build = ":LazySpeakInstall",
  opts = {
    agent = { adapter = "claudecode" },
  },
}
```

`:LazySpeakInstall` will build and install the `lazyspeak` daemon binary via `cargo install`.

When you run `:LazySpeakStart`, the plugin automatically starts `llama-server` which downloads [ggml-org/Voxtral-Mini-3B-2507-GGUF](https://huggingface.co/ggml-org/Voxtral-Mini-3B-2507-GGUF) (Apache 2.0, ~3.2 GB) on first run. It shuts down with `:LazySpeakStop`.

#### External STT server (advanced)

To use your own STT server instead of the auto-managed llama-server:

```lua
require("lazyspeak").setup({
  model = {
    server_url = "http://127.0.0.1:8674",
  },
})
```

The server must expose an OpenAI-compatible `/v1/audio/transcriptions` endpoint.

### Manual installation

```sh
# 1. Clone the plugin
git clone https://github.com/urmzd/lazyspeak.nvim ~/.local/share/nvim/lazy/lazyspeak.nvim

# 2. Build and install the daemon binary
cd ~/.local/share/nvim/lazy/lazyspeak.nvim
cargo install --path crates/lazyspeak
```

### Verify installation

Open Neovim and run:

```vim
:checkhealth lazyspeak
```

## Agent Setup

lazyspeak.nvim needs a coding agent to dispatch transcripts to. Pick one:

### Claude Code (default)

Install [Claude Code](https://docs.anthropic.com/en/docs/claude-code), then:

```lua
require("lazyspeak").setup({
  agent = { adapter = "claudecode" },
})
```

The adapter auto-discovers a running Claude Code instance or spawns a new CLI process.

### ACP-compatible agents

Any agent that speaks the [Agent Communication Protocol](https://github.com/anthropics/agent-protocol) works:

```lua
require("lazyspeak").setup({
  agent = {
    adapter = "acp",
    cmd = { "gemini", "--acp" },           -- Gemini CLI
    -- cmd = { "goose", "session", "--acp" }, -- Goose
    -- cmd = { "codex", "--acp" },            -- Codex
  },
})
```

## Usage

### Keybindings

| Key | Mode | Action |
|-----|------|--------|
| `<leader>ls` | n | Push-to-talk (press to listen, press again to send) |
| `<leader>lS` | n | Toggle continuous listening (VAD auto-segments) |
| `<leader>lc` | n | Cancel current recording or agent request |
| `<leader>lh` | n | Show transcript history |
| `<leader>lu` | n | Undo last agent edit (revert snapshot) |
| `<leader>la` | n | Switch agent |

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
| `:LazySpeakInstall` | Build daemon binary |

### Voice commands

These phrases are intercepted locally before reaching the agent:

| Phrase | Action |
|--------|--------|
| "undo", "revert", "go back" | Revert last agent edit |
| "undo all", "revert everything" | Revert all edits in session |
| "cancel", "stop", "nevermind" | Cancel current recording/request |

### Status line

Add to your status line (lualine, etc.):

```lua
require("lazyspeak").status()
-- Returns: "" (inactive), "ls:mic" (listening), "ls:..." (transcribing),
--          "ls:>>>" (agent working), "ls:???" (awaiting permission)
```

## Configuration

Full configuration with defaults:

```lua
require("lazyspeak").setup({
  agent = {
    adapter = "claudecode",  -- "claudecode" | "acp"
    -- cmd = { "gemini", "--acp" },  -- for ACP adapter
    -- auto_approve = false,
  },

  model = {
    hf_repo = "ggml-org/Voxtral-Mini-3B-2507-GGUF",
    server_port = 8674,
    -- server_url = "http://127.0.0.1:8674",  -- use external server
  },

  audio = {
    sample_rate = 16000,
    channels = 1,
    vad_threshold = 0.5,
    silence_duration_ms = 1000,
    max_duration_ms = 30000,
  },

  ui = {
    float_position = "bottom-right",
    float_width = 40,
    show_waveform = true,
    statusline = true,
  },

  snapshot = {
    enabled = true,
    max_stack = 20,
    use_git = true,  -- prefer git stash, falls back to in-memory
  },

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

## Architecture

```
Neovim (Lua plugin)
  |
  | stdin/stdout JSON lines
  v
lazyspeak daemon (Rust binary)
  |  - mic capture (cpal)
  |  - energy-based VAD
  |  - STT via llama-server (HTTP)
  v
transcript -> adapter -> agent -> edits applied in Neovim
```

The daemon uses a `SpeechTranscriber` trait to abstract over STT backends. The plugin uses an Internal Representation (IR) to decouple from any specific agent protocol. Both layers are pluggable.

## Development

```sh
just build          # Build daemon (release)
just test           # Run tests
just lint           # Clippy + format check
just fmt            # Format code
just daemon-dev     # Run daemon in dev mode
just nvim-dev       # Launch Neovim with plugin loaded
```

### Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `LAZYSPEAK_STT_URL` | `http://127.0.0.1:8674` | llama-server URL |

## License

[Apache 2.0](LICENSE)
