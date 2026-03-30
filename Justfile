default:
    @just --list

# Install project dependencies
install:
    cargo fetch

# === BUILD ===

# Build the daemon binary
build:
    cargo build --release

# Remove build artifacts
clean:
    cargo clean

# === TEST ===

# Run tests
test:
    cargo test --workspace

# === LINT ===

# Run clippy
lint:
    cargo clippy --workspace -- -D warnings

# === FORMAT ===

# Format all code
fmt:
    cargo fmt --all
    taplo fmt || true
    alejandra . 2>/dev/null || true

# Check formatting without modifying files
fmt-check:
    cargo fmt --all -- --check

# === CHECK ===

# Run all CI checks (fmt + lint + test)
check: fmt-check lint test

# Full CI gate
ci: fmt-check lint build test

# === DEV ===

# Install the daemon binary
install-bin:
    cargo install --path crates/lazyspeak

# Run daemon in dev mode
daemon-dev:
    cargo run --bin lazyspeak

# Test Neovim plugin loads
nvim-dev:
    nvim --cmd 'set rtp+=.' -c 'lua require("lazyspeak").setup()'

# Convert Voxtral HF model to GGUF Q4_K_M (requires Python + llama.cpp)
convert-model:
    pip install gguf transformers torch mistral-common
    python scripts/convert_model.py

