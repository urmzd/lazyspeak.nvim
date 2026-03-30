default:
    @just --list

# Build the daemon binary
build:
    cargo build --release

# Run clippy + format check
lint:
    cargo clippy --workspace -- -D warnings
    cargo fmt --check

# Format code
fmt:
    cargo fmt

# Run tests
test:
    cargo test --workspace

# Install the daemon binary
install:
    cargo install --path crates/lazyspeak

# Run daemon in dev mode
daemon-dev:
    cargo run --bin lazyspeak

# Test Neovim plugin loads
nvim-dev:
    nvim --cmd 'set rtp+=.' -c 'lua require("lazyspeak").setup()'

# Convert official Voxtral model to ONNX (requires Python + deps)
convert-model:
    pip install transformers torch optimum[exporters] onnxruntime onnxslim
    python scripts/convert_model.py

# Download Voxtral GGUF model for HTTP/llama-server backend
download-model:
    mkdir -p ~/.local/share/lazyspeak
    curl -L -H "Authorization: Bearer ${HF_TOKEN}" \
        -o ~/.local/share/lazyspeak/voxtral-mini-3b-q4_k_m.gguf \
        "https://huggingface.co/mistralai/Voxtral-Mini-3B-2507-GGUF/resolve/main/voxtral-mini-3b-q4_k_m.gguf"
