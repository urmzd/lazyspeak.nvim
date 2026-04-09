# Roadmap

Current state and planned work for lazyspeak.nvim.

## Completed (v0.1–v0.4)

- [x] Local STT via Voxtral Mini 3B (llama-server, GGUF Q4_K_M)
- [x] Cross-platform audio capture (cpal: Core Audio, ALSA, WASAPI)
- [x] Energy-based voice activity detection
- [x] Push-to-talk and continuous listening modes
- [x] ACP adapter (JSON-RPC 2.0 over stdio)
- [x] Claude Code adapter (CLI pipe)
- [x] Internal Representation (IR) decoupling plugin from agent protocols
- [x] Git stash snapshots with voice-driven undo/revert
- [x] Floating UI with waveform, transcript, and permission prompts
- [x] Auto-managed llama-server lifecycle
- [x] Async/tokio pipeline architecture (streamsafe)
- [x] `:LazySpeakInstall` (cargo build + model auto-download)

## Near-term

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

### Claude Code WebSocket adapter

Upgrade the Claude Code adapter from CLI pipe (`claude --print -p`) to the
full IDE protocol over WebSocket. Enables streaming responses, tool call
visibility, and richer permission handling matching what VS Code gets.

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
