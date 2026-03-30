#!/usr/bin/env python3
"""Convert Voxtral-Mini-3B-2507 from HuggingFace to ONNX format.

Downloads the official weights from mistralai/Voxtral-Mini-3B-2507 (Apache 2.0,
ungated) and exports three ONNX submodels:
  - audio_encoder.onnx   (audio tower + multi-modal projector)
  - embed_tokens.onnx    (token embedding lookup)
  - decoder.onnx         (LM forward pass, no KV cache — full-context per step)

Also copies the tokenizer for use at runtime.

Usage:
    pip install transformers torch mistral-common onnxruntime
    python scripts/convert_model.py [--output ~/.local/share/lazyspeak] [--quantize q4]
"""

import argparse
import sys
from pathlib import Path

import torch
import torch.nn as nn

MODEL_ID = "mistralai/Voxtral-Mini-3B-2507"
DEFAULT_OUTPUT = Path.home() / ".local" / "share" / "lazyspeak"


def check_deps():
    """Verify required Python packages are installed."""
    missing = []
    for pkg in ["transformers", "torch", "onnxruntime"]:
        try:
            __import__(pkg)
        except ImportError:
            missing.append(pkg)
    if missing:
        print(f"Missing packages: {', '.join(missing)}")
        print("Install with: pip install transformers torch mistral-common onnxruntime")
        sys.exit(1)


# --- Wrapper modules for clean ONNX export ---


class AudioEncoderWrapper(nn.Module):
    """Audio tower + reshape + multi-modal projector → projected hidden states.

    Voxtral reshapes the encoder output from [1, T', 1280] to [-1, 5120]
    (concatenating 4 adjacent frames) before projecting to the LM hidden size.
    """

    def __init__(self, audio_tower, projector, intermediate_size: int):
        super().__init__()
        self.audio_tower = audio_tower
        self.projector = projector
        self.intermediate_size = intermediate_size

    def forward(self, mel: torch.Tensor) -> torch.Tensor:
        # mel: [1, n_mels, n_frames]
        hidden = self.audio_tower(mel).last_hidden_state  # [1, T', 1280]
        # Reshape: concatenate groups of frames → [1, T'/4, 5120]
        hidden = hidden.reshape(-1, self.intermediate_size)  # [T'/4, 5120]
        projected = self.projector(hidden)  # [T'/4, 3072]
        return projected.unsqueeze(0)  # [1, T'/4, 3072]


class EmbedTokensWrapper(nn.Module):
    """Token ID → embedding lookup."""

    def __init__(self, embed_tokens):
        super().__init__()
        self.embed_tokens = embed_tokens

    def forward(self, input_ids: torch.Tensor) -> torch.Tensor:
        return self.embed_tokens(input_ids)


class DecoderWrapper(nn.Module):
    """Full LM forward: input_embeds → logits (no KV cache).

    For short transcription tasks (~50 tokens), running full context each step
    is acceptable and avoids the complexity of KV-cache ONNX export.
    """

    def __init__(self, language_model):
        super().__init__()
        self.language_model = language_model

    def forward(self, inputs_embeds: torch.Tensor) -> torch.Tensor:
        out = self.language_model(inputs_embeds=inputs_embeds, use_cache=False)
        return out.logits


def load_model():
    """Load Voxtral model and processor."""
    from transformers import AutoModel, AutoProcessor

    print(f"Loading {MODEL_ID}...")
    model = AutoModel.from_pretrained(
        MODEL_ID,
        trust_remote_code=True,
        dtype=torch.float32,
        attn_implementation="eager",
    )
    model.eval()

    processor = AutoProcessor.from_pretrained(MODEL_ID, trust_remote_code=True)
    return model, processor


def export_audio_encoder(model, onnx_dir: Path):
    """Export audio_tower + projector as a single ONNX model."""
    intermediate_size = model.config.audio_config.intermediate_size
    wrapper = AudioEncoderWrapper(
        model.audio_tower, model.multi_modal_projector, intermediate_size
    )
    wrapper.eval()

    # Dummy input: 30s of audio at 128 mel bins, 3000 frames
    dummy_mel = torch.randn(1, 128, 3000)

    out_path = onnx_dir / "audio_encoder.onnx"
    print(f"  Exporting audio encoder → {out_path}")

    torch.onnx.export(
        wrapper,
        (dummy_mel,),
        str(out_path),
        input_names=["mel"],
        output_names=["hidden_states"],
        dynamic_axes={"mel": {2: "n_frames"}, "hidden_states": {1: "seq_len"}},
        opset_version=17,
        dynamo=False,
    )
    print(f"  ✓ audio_encoder.onnx ({out_path.stat().st_size / 1e6:.1f} MB)")


def export_embed_tokens(model, onnx_dir: Path):
    """Export token embedding lookup."""
    wrapper = EmbedTokensWrapper(model.language_model.model.embed_tokens)
    wrapper.eval()

    dummy_ids = torch.tensor([[1]], dtype=torch.long)  # BOS token

    out_path = onnx_dir / "embed_tokens.onnx"
    print(f"  Exporting embed_tokens → {out_path}")

    torch.onnx.export(
        wrapper,
        (dummy_ids,),
        str(out_path),
        input_names=["input_ids"],
        output_names=["embeddings"],
        dynamic_axes={"input_ids": {1: "seq_len"}, "embeddings": {1: "seq_len"}},
        opset_version=17,
        dynamo=False,
    )
    print(f"  ✓ embed_tokens.onnx ({out_path.stat().st_size / 1e6:.1f} MB)")


def export_decoder(model, onnx_dir: Path):
    """Export LM decoder (no KV cache — full context per step)."""
    wrapper = DecoderWrapper(model.language_model)
    wrapper.eval()

    hidden_size = model.language_model.config.hidden_size
    # Dummy: batch=1, seq_len=10, hidden_size
    dummy_embeds = torch.randn(1, 10, hidden_size)

    out_path = onnx_dir / "decoder.onnx"
    print(f"  Exporting decoder → {out_path}")

    torch.onnx.export(
        wrapper,
        (dummy_embeds,),
        str(out_path),
        input_names=["inputs_embeds"],
        output_names=["logits"],
        dynamic_axes={
            "inputs_embeds": {1: "seq_len"},
            "logits": {1: "seq_len"},
        },
        opset_version=17,
        dynamo=False,
    )
    print(f"  ✓ decoder.onnx ({out_path.stat().st_size / 1e6:.1f} MB)")


def save_tokenizer(processor, output_dir: Path):
    """Save tokenizer for runtime use."""
    tokenizer = processor.tokenizer
    # MistralCommonTokenizer wraps a tekken tokenizer — save its vocab
    tokenizer.save_pretrained(str(output_dir))
    print(f"  ✓ tokenizer saved to {output_dir}")


def quantize_onnx(onnx_dir: Path, variant: str):
    """Quantize ONNX models using onnxruntime quantization."""
    try:
        from onnxruntime.quantization import quantize_dynamic, QuantType
    except ImportError:
        print("Skipping quantization — install onnxruntime for quantization support")
        return

    type_map = {
        "q4": QuantType.QUInt4x2,
        "q8": QuantType.QInt8,
    }

    if variant not in type_map:
        print(f"Unknown quantization variant: {variant} (supported: q4, q8)")
        return

    quant_type = type_map[variant]
    print(f"\nQuantizing to {variant}...")

    for model_file in sorted(onnx_dir.glob("*.onnx")):
        if f"_{variant}" in model_file.stem:
            continue

        out_name = model_file.stem + f"_{variant}.onnx"
        out_path = onnx_dir / out_name
        print(f"  Quantizing {model_file.name} → {out_name}...")

        try:
            quantize_dynamic(
                str(model_file),
                str(out_path),
                weight_type=quant_type,
            )
            orig_size = model_file.stat().st_size / 1e6
            quant_size = out_path.stat().st_size / 1e6
            print(f"  ✓ {out_name} ({orig_size:.1f} MB → {quant_size:.1f} MB)")
        except Exception as e:
            print(f"  ✗ Failed to quantize {model_file.name}: {e}")


def main():
    parser = argparse.ArgumentParser(description="Convert Voxtral to ONNX")
    parser.add_argument(
        "--output",
        "-o",
        type=Path,
        default=DEFAULT_OUTPUT,
        help=f"Output directory (default: {DEFAULT_OUTPUT})",
    )
    parser.add_argument(
        "--quantize",
        "-q",
        type=str,
        default=None,
        help="Quantization variant after export (e.g. q4, q8)",
    )
    parser.add_argument(
        "--skip-export",
        action="store_true",
        help="Skip ONNX export (only quantize / copy tokenizer)",
    )
    args = parser.parse_args()

    check_deps()

    onnx_dir = args.output / "onnx"
    onnx_dir.mkdir(parents=True, exist_ok=True)

    if not args.skip_export:
        model, processor = load_model()

        print("\nExporting ONNX models...")
        export_audio_encoder(model, onnx_dir)
        export_embed_tokens(model, onnx_dir)
        export_decoder(model, onnx_dir)

        print("\nSaving tokenizer...")
        save_tokenizer(processor, args.output)

        # Free memory before quantization
        del model, processor
        torch.cuda.empty_cache() if torch.cuda.is_available() else None

    if args.quantize:
        quantize_onnx(onnx_dir, args.quantize)

    print(f"\nDone! Model files: {onnx_dir}")
    print("Set LAZYSPEAK_BACKEND=onnx to use the ONNX backend.")


if __name__ == "__main__":
    main()
