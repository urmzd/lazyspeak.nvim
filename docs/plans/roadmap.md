# Roadmap

Current state and planned work for lazyspeak.nvim.

## Completed (v0.1–v0.4)

- [x] Local STT via Voxtral Mini 3B (llama-server, GGUF Q4_K_M)
- [x] Cross-platform audio capture (cpal: Core Audio, ALSA, WASAPI)
- [x] Energy-based voice activity detection
- [x] Push-to-talk and continuous listening modes
- [x] ACP adapter (JSON-RPC 2.0 over stdio, ACP v1) with streamed agent
      output, tool calls, file edits, and permission prompts
- [x] Claude Code over ACP via `@agentclientprotocol/claude-agent-acp`
- [x] Interim (partial) transcripts + low-latency VAD endpointing for a
      realtime feel
- [x] Internal Representation (IR) decoupling plugin from agent protocols
- [x] Pre-turn snapshots with voice-driven undo/revert, stored under
      `$XDG_STATE_HOME` rather than in the user's `git stash`
- [x] Session sidebar: fixed status header (stt/daemon/agent signals) over a
      framed conversation, one block per turn, tool calls as `Read(path)` with
      result glyphs, re-flowing on resize
- [x] Full teardown on `VimLeavePre` so exiting never strands a process
- [x] Non-blocking `llama-server` health probe with an idle-progress watchdog,
      replacing a `io.popen`+curl poll that could freeze the editor indefinitely
- [x] Auto-managed llama-server lifecycle
- [x] Async/tokio pipeline architecture (streamsafe)
- [x] `:LazySpeakInstall` (cargo build + model auto-download)

## Near-term

### Editor context in the prompt

Today the agent receives only the transcript plus `cwd` at session creation. It
is never told the active buffer, cursor position, or visual selection, so
deictic prompts ("this function", "the line I'm on", "fix this") cannot work —
the user has to name files and symbols explicitly.

**Approach:** Attach context to `session/prompt` alongside the text block. ACP
provides `resource_link` (a URI reference the agent may fetch) and `resource`
(inlined content) content blocks, which is the protocol-correct vehicle rather
than stuffing a preamble into the transcript. Send the active buffer's path as a
`resource_link` on every turn, plus cursor line and any visual selection range.
Inline the selection itself when one exists, since that is usually the subject.

**Open questions:** How much to send by default without bloating every prompt or
leaking unrelated buffers; whether context should be opt-in per turn via a voice
command ("with this file", "just the selection"); and how agents that ignore
`resource_link` should be handled.

**Impact:** The difference between dictating a specification and dictating an
instruction. This is the largest single gap between lazyspeak and using a coding
agent by hand.

### Silero VAD — replace energy-based VAD

The current RMS energy threshold works in quiet environments but degrades with
background noise, keyboard clatter, or music. Silero VAD is an ONNX model
purpose-built for voice activity detection.

**Approach:** Add `ort` (ONNX Runtime Rust bindings, v2.0) as a dependency.
`ort` auto-downloads pre-built ONNX Runtime binaries — no C++ compilation
required. Silero distributes ready-made ONNX models. CoreML acceleration on
macOS, CUDA on Linux.

**Impact:** More accurate speech/silence boundaries, fewer false triggers, better
handling of noisy environments. The energy-based VAD can remain as a zero-dep
fallback.

### Context injection

Automatically include the current buffer, visual selection, and LSP diagnostics
alongside the voice transcript when dispatching to the agent. The agent gets
the same context it would have in a text-based IDE interaction.

### Pre-built binaries

Publish platform binaries (macOS ARM, macOS x86, Linux ARM, Linux x86) via
GitHub Releases. Eliminates the Rust toolchain requirement for end users.
`:LazySpeakInstall` would download the appropriate binary instead of compiling.

## Mid-term

### In-process STT — eliminate llama-server

The current architecture runs llama-server as a separate process and
communicates over HTTP. This works but adds process management complexity and
startup latency.

**Options evaluated:**

| Crate | Model format | GPU | Build cost | Status |
|-------|-------------|-----|------------|--------|
| `llama-cpp-2` | GGUF (existing model) | Metal, CUDA, Vulkan | Medium (compiles llama.cpp via -sys crate) | Active, tracks upstream daily |
| `candle` | Safetensors (different from current GGUF) | Metal, CUDA | Low (pure Rust + optional accelerate) | Active, has Voxtral + Whisper implementations |
| `whisper-rs` | GGML (whisper.cpp models only) | Metal, CUDA, CoreML | Medium (compiles whisper.cpp via -sys crate) | Stable, repo moved to Codeberg |

`llama-cpp-2` is the path of least resistance — same GGUF model file, same
inference engine, just linked in-process instead of over HTTP. Trades HTTP
overhead for build complexity (C++ compilation of llama.cpp).

`candle` is the pure-Rust path but requires a different model format
(safetensors). It has working Voxtral and Whisper implementations with Metal
support. Better long-term bet if the ecosystem matures.

**Decision deferred** — the HTTP boundary is not a bottleneck today. Inference
time dominates latency, not the HTTP round-trip. Revisit when pre-built
binaries are in place and build complexity matters less.

### Native-audio fast path (Gemini)

Most ACP agents (including Claude) take only text, so lazyspeak transcribes
locally and sends a text content block. Gemini CLI (`gemini --acp`) advertises
`promptCapabilities.audio` and is natively multimodal, so an opt-in fast path
could forward the raw audio content block and skip local STT for that agent.

### True streaming STT

Partial transcripts give a realtime feel on top of batch Voxtral. Sub-200ms
streaming would need a causal model (e.g. Voxtral Realtime) on a runtime that
supports incremental encoding — a model + backend swap, tracked separately so
it does not compromise the local-only, single-binary ethos.

### Wake word activation

Optional hands-free activation without a keybind. Requires always-on VAD
(Silero) running in the background with low CPU overhead, plus a lightweight
keyword spotter (e.g. "hey code", "listen").

## Long-term

### Voice feedback (TTS)

Optional text-to-speech for agent responses via Piper (MIT, ~50 MB models) or
a future Voxtral TTS endpoint. Read back confirmations, errors, or summaries
so the user doesn't need to look at the screen.

### ACP agent registry

Browse and install agents from the ACP registry directly within Neovim.
`:LazySpeakAgent browse` to discover available agents.

### Multi-session support

Run multiple concurrent agent sessions — e.g., one agent refactoring auth
while another writes tests. Each session maintains its own snapshot stack and
UI pane.

### Adaptive audio pipeline

- Noise gate / noise suppression (RNNoise or similar)
- Automatic gain control
- Adaptive VAD thresholds based on ambient noise floor
- Support for non-default audio input devices

## Non-goals

- **Cloud STT** — local-only is a core design principle
- **TTS by default** — voice feedback is opt-in, not the default experience
- **GUI** — this is a terminal/Neovim plugin, no Electron or web UI
- **Model training** — we consume pre-trained models, not train them
