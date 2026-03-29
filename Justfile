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
    cargo install --path crates/lazyspeak-cli

# Run daemon in dev mode
daemon-dev:
    cargo run --bin lazyspeak

# Test Neovim plugin loads
nvim-dev:
    nvim --cmd 'set rtp+=.' -c 'lua require("lazyspeak").setup()'

# Download Voxtral model
download-model:
    mkdir -p ~/.local/share/lazyspeak
    curl -L -o ~/.local/share/lazyspeak/voxtral-mini-3b-q4_k_m.gguf \
        "https://huggingface.co/mistralai/Voxtral-Mini-3B-2507-GGUF/resolve/main/voxtral-mini-3b-q4_k_m.gguf"
