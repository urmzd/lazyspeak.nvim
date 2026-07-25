<p align="center">
  <h1 align="center">lazyspeak.nvim</h1>
  <p align="center">
    Voice-driven coding for Neovim. Speak your intent, edits appear in your editor.
    <br /><br />
    <a href="#installation">Install</a>
    &middot;
    <a href="https://github.com/urmzd/lazyspeak.nvim/issues">Report Bug</a>
    &middot;
    <a href="#agent-setup">Agents</a>
  </p>
</p>

<p align="center">
  <a href="https://github.com/urmzd/lazyspeak.nvim/actions/workflows/ci.yml"><img src="https://github.com/urmzd/lazyspeak.nvim/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  &nbsp;
  <a href="LICENSE"><img src="https://img.shields.io/github/license/urmzd/lazyspeak.nvim" alt="License"></a>
</p>

<p align="center">
  <img src="showcase/lazyspeak-demo.gif" alt="lazyspeak.nvim demo" width="80%">
</p>

```
Mic -> Voxtral Mini 3B (local STT) -> transcript -> adapter -> agent -> Neovim
         ~3.2 GB GGUF, Apache 2.0      Agent Client Protocol (ACP)
```

No cloud STT dependency. No TTS. You speak, it codes.

## Prerequisites

| Tool | Purpose | Install |
|------|---------|---------|
| Neovim >= 0.10 | Editor | [neovim.io](https://neovim.io) |
| Rust toolchain | Build daemon binary | `curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \| sh` |
| llama.cpp | Local STT inference | `brew install llama.cpp` |
| Node.js >= 18 | Run the Claude Code ACP bridge (`npx`) | [nodejs.org](https://nodejs.org) |
| An [ACP](https://agentclientprotocol.com) agent (Claude Code, Gemini, Goose, …) | Coding intelligence | See [Agent Setup](#agent-setup) |

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

lazyspeak.nvim speaks the [Agent Client Protocol (ACP)](https://agentclientprotocol.com)
to any compatible agent over stdio. Agent responses, tool calls, file edits, and
permission prompts all stream back into Neovim live. Pick an agent:

### Claude Code (default)

The `claudecode` adapter launches Anthropic's official ACP bridge,
[`@agentclientprotocol/claude-agent-acp`](https://www.npmjs.com/package/@agentclientprotocol/claude-agent-acp)
(formerly `@zed-industries/claude-code-acp`), via `npx` — no global install required:

```lua
require("lazyspeak").setup({
  agent = { adapter = "claudecode" },
})
```

**Authentication:** the bridge inherits your environment, so either export
`ANTHROPIC_API_KEY`, or run `claude login` once (its cached token is reused). No
in-editor login flow is needed.

> Claude has no native audio input, so lazyspeak always transcribes locally
> (Voxtral) and sends **text** to the agent.

### Other ACP agents

Point the `acp` adapter at any ACP agent's launch command:

```lua
require("lazyspeak").setup({
  agent = {
    adapter = "acp",
    cmd = { "gemini", "--acp" },  -- Gemini CLI (natively multimodal)
    -- cmd = { "goose", "acp" },  -- Goose
    -- cmd = { "claude-agent-acp" }, -- Claude bridge installed globally
  },
})
```

## First run

End to end, from a fresh install to your first voice-driven edit.

**1. Confirm the pieces are in place.**

```vim
:checkhealth lazyspeak
```

This checks the `lazyspeak` daemon binary, `llama-server`, `npx`, your Anthropic
credentials, the Voxtral model file, and whether `setup()` has run. If the daemon
line warns, run `:LazySpeakInstall` to build it (`cargo install --path
crates/lazyspeak`, roughly a minute). The model warning is expected until your
first `<leader>ls`.

**2. Open a real file** in the project you want to work on. The agent operates
on your working directory, and snapshots are taken relative to it.

**3. Start a session** with `<leader>ls`.

The sidebar opens on the right. Its header carries three process signals, the
current phase, and the keys that are useful right now, so you can always see
which part is holding things up and what to press next:

```
 ● stt  ● daemon  ◐ agent
 ⠹ downloading model 47%
 <leader>lc interrupt   ? help
────────────────────────────────
```

`○` down, `◐` starting, `●` up, `✗` failed. Until your first turn, the body
below lists every key; press `?` in the sidebar to bring that reference back at
any time, or `:LazySpeakHelp` from anywhere.

On the very first run two slow things happen here, both one-time:

- `llama-server` downloads the Voxtral GGUF. The header tracks it as
  `downloading model NN%`, then `loading model...`. This can take a while on a
  slow link; the editor stays responsive throughout, and the run is only
  abandoned if the server goes completely silent for two minutes.
- macOS prompts for **microphone access** for your terminal application. Grant
  it. If you dismiss the prompt, recording silently produces nothing, and you
  will need to enable it under System Settings > Privacy & Security > Microphone.

Wait for the header to read `press <Space> to record`.

**4. Speak.** Press `<Space>` to start recording, say what you want, press
`<Space>` again to send.

```
"add a doc comment to the parse function in core.lua"
```

Name the file you mean. The agent is told your working directory and can read
files itself, but it is **not** told which buffer you have open or where your
cursor is, so "the function under the cursor" will not work. See
[Editor context](#editor-context).

Your interim transcript appears in a provisional box while you talk, and is
replaced by the final text when you stop.

**5. Watch it work.** Each turn is framed in the sidebar, and each thing the
agent does gets its own block:

```
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
```

**6. Approve the edit.** With the default `auto_approve = false`, every file
change raises a `vim.ui.select` prompt. The ask and your answer are both
recorded in the conversation:

```
⏺ ? Edit middleware.lua?
  ⎿ allow once
```

**7. Undo if you want it back.** `<leader>lu` reverts the last agent edit via the
snapshot stack. Saying "undo", "revert", or "go back" does the same thing without
touching the keyboard. Worth exercising once early, before you trust it with
something real.

**8. Finish up.** `<Esc>` dismisses the UI but leaves the daemon warm, so the
next `<leader>ls` is instant. `:LazySpeakStop` shuts everything down and frees
the model's memory. Quitting Neovim tears it all down either way.

### Tuning after a few turns

| Symptom | Knob |
|---------|------|
| It cuts you off mid-sentence | raise `audio.silence_duration_ms` (default 400) |
| It waits too long before sending | lower `audio.silence_duration_ms` |
| It triggers on background noise | raise `audio.vad_threshold` (default 0.01) |
| Permission prompts are tedious | `agent.auto_approve = true` |
| The sidebar is in the way | `ui.sidebar_auto_open = false`, open it with `<leader>ll` |
| The sidebar is too narrow or wide | `ui.sidebar_width` (default 48) |
| You want it on the left | `ui.sidebar_position = "left"` |

## Resource requirements

Voxtral Mini 3B runs entirely on your machine, so the STT server is the main
cost. Budget roughly:

| | |
|---|---|
| Disk | ~3 GB for the GGUF plus audio encoder, downloaded once |
| Memory, resident | ~4-5 GB once weights, KV cache, and Metal buffers are up |
| Practical floor | 16 GB unified memory; Apple Silicon uses Metal automatically |

The failure mode worth knowing about is memory contention rather than raw
capacity. If you already run another local model, the two compete: Ollama's
server, for instance, is often launched with `--no-mmap`, which pins its weights
so they cannot be evicted through the page cache. Two hot 3B models plus an
editor on a 16-24 GB machine will push the system into swap, and model loading
slows from seconds to minutes.

If startup crawls, check pressure before blaming the plugin:

```sh
sysctl vm.swapusage      # swap nearly full means you are already thrashing
pgrep -fl llama-server   # something else may already hold a model resident
```

Stopping the other model, or a reboot to reclaim swap, is usually the fix. The
sidebar header distinguishes the cases for you: a moving `downloading model NN%`
is healthy, a `loading model...` that sits for minutes is memory pressure.

## Usage

### Keybindings

| Key | Mode | Action |
|-----|------|--------|
| `<leader>ls` | n | Open the session (starts the daemon if needed) |
| `<Space>` | n | Start/stop recording while the session is open |
| `<Esc>` | n | Cancel recording and dismiss the UI |
| `<leader>lc` | n | Cancel current recording or agent request |
| `<leader>lu` | n | Undo last agent edit (revert snapshot) |
| `<leader>ll` | n | Toggle the session sidebar |

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
| `:LazySpeakSnapshotsPrune` | Drop orphaned `lazyspeak:` git stash entries |
| `:LazySpeakInstall` | Build daemon binary |

### The sidebar

One surface, on the right, full height. A fixed four-row header carries the three
process signals, the current phase, and contextual hints; below it the session
reads as a conversation.

Hints follow state, so they only ever show keys that do something right now:

| State | Hints |
|-------|-------|
| idle | `<leader>ls talk`, `<leader>lu undo` |
| ready | `<Space> record`, `<Esc> close` |
| recording | `<Space> send`, `<Esc> cancel` |
| agent working | `<leader>lc interrupt` |
| awaiting permission | `answer the prompt` |

They reflect what you actually bound, not the defaults. Two keys are local to the
sidebar window: `?` toggles the full reference, `q` closes it.

Colours link to standard groups (`DiagnosticOk`/`Warn`/`Error`, `Comment`,
`Title`, `Function`), so the sidebar follows your colorscheme. Override any of
the `LazySpeak*` groups to change it.

Every item is framed as its own block, so you can tell a response from a file
read at a glance: your turns are boxed with a timestamp, agent output and
thinking are bulleted, and tool calls render as `Read(path)` with a `⎿` result
line carrying `✓`, `◐`, or `✗`.

Text is hard-wrapped to the window width rather than soft-wrapped, so borders
and gutters stay aligned. Resizing the window re-flows the whole conversation.

The sidebar persists across turns and has real scrollback. Following the tail
pauses automatically when you scroll back, so reading mid-stream does not yank
you to the bottom.

| Action | Sidebar window | Conversation | Daemon |
|--------|---------------|--------------|--------|
| `<Esc>` / `:LazySpeakDismiss` | closed | kept | running |
| `:LazySpeakStop` | closed | deleted | stopped |
| Exit Neovim | closed | deleted | stopped |

Everything shuts down on exit, so quitting Neovim never leaves the daemon,
`llama-server`, or the agent process running.

### Editor context

What the agent receives today is deliberately minimal:

| Sent | When |
|------|------|
| Working directory (`cwd`) | once, at `session/new` |
| Your transcript, as a text block | every turn |

That is all. The agent is **not** told which buffer is open, your cursor
position, the visual selection, or any buffer contents. It advertises
`fs.readTextFile` and `fs.writeTextFile`, so it can read and edit any file under
the working directory on its own initiative, but it has to find them first.

The practical consequence: say what you mean by name. "Rename `handle_transcript`
in core.lua" works. "Fix this function" or "the line I'm on" does not, because
there is no *this*.

Automatic context injection (current file, cursor line, selection) is not yet
implemented. It is tracked in [docs/roadmap.md](docs/roadmap.md).

### Undo and snapshots

Before every turn is dispatched, the tracked files that differ from `HEAD` are
copied aside, so `<leader>lu` (or saying "undo") can put them back.

Snapshots live **outside your repository**, under Neovim's state directory:

```
$XDG_STATE_HOME/nvim/lazyspeak/snapshots/<session>/<snapshot>/
```

Nothing is written to the repo itself until an undo actually restores files. An
earlier version used `git stash create` plus `git stash store`, which put plugin
bookkeeping into your own `git stash list` where it accumulated and mixed with
your real stashes.

State rather than config or data because this is regenerable session state, not
settings you wrote, and it is where Neovim already keeps undo files, swap, and
shada.

Lifecycle:

| Event | Effect |
|-------|--------|
| Turn changes nothing | snapshot handed back immediately |
| Past `snapshot.max_stack` | oldest snapshot deleted from disk with its record |
| `:LazySpeakStop` or quitting | the whole session's snapshots deleted |
| Startup | session dirs older than `snapshot.max_age_days` swept |

Undo restores the contents of files captured at snapshot time and returns to
`HEAD` any file the agent dirtied that was clean beforehand. Files the agent
created are left in place, since deleting them is not recoverable from here.
Untracked files are not captured. Undo requires a git repository; outside one no
snapshot is taken.

`:LazySpeakSnapshotsPrune` sweeps stale session directories and, if you used a
version that wrote to `git stash`, offers to drop those leftovers. It lists them
and asks first, and only ever considers entries whose message begins with
`lazyspeak:`.

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
    -- cmd = { "gemini", "--acp" },  -- override launch command (acp adapter)
    auto_approve = false,    -- false = prompt on every permission; true = auto-allow
  },

  model = {
    hf_repo = "ggml-org/Voxtral-Mini-3B-2507-GGUF",
    server_port = 8674,
    -- server_url = "http://127.0.0.1:8674",  -- use external server
  },

  audio = {
    sample_rate = 16000,
    channels = 1,
    vad_threshold = 0.01,        -- RMS energy threshold for speech
    silence_duration_ms = 400,   -- trailing silence before finalizing (latency knob)
    max_duration_ms = 30000,
    partial_interval_ms = 700,   -- interim transcript cadence while speaking (0 disables)
  },

  ui = {
    sidebar_position = "right",   -- "right" | "left"
    sidebar_width = 48,
    sidebar_auto_open = true,     -- open the sidebar when a session starts
    statusline = true,
  },

  snapshot = {
    enabled = true,
    max_stack = 20,      -- snapshots kept per session
    max_age_days = 7,    -- sweep sessions a crash left behind
  },

  keys = {
    push_to_talk = "<leader>ls",
    cancel = "<leader>lc",
    undo = "<leader>lu",
    sidebar = "<leader>ll",
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
| `LAZYSPEAK_VAD_THRESHOLD` | `0.01` | RMS energy threshold for speech detection |
| `LAZYSPEAK_SILENCE_MS` | `400` | Trailing silence before an utterance is finalized |
| `LAZYSPEAK_MAX_MS` | `30000` | Max utterance length before forced finalization |
| `LAZYSPEAK_PARTIAL_MS` | `700` | Interim transcript cadence while speaking (0 disables) |

These are set automatically from your `audio` config; override them directly only when running the daemon standalone.

## License

[Apache 2.0](LICENSE)
