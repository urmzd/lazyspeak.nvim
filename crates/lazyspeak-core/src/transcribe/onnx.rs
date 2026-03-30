//! ONNX Runtime transcription backend.
//!
//! Runs Voxtral inference entirely in-process — no external server needed.
//! Requires pre-exported ONNX model files (see `scripts/convert_model.py`).
//!
//! Pipeline: audio → mel spectrogram → encoder → decoder (autoregressive) → text

use super::{SpeechTranscriber, TranscribeResult};
use anyhow::Result;
use ndarray::Array2;
use ort::session::Session;
use ort::session::builder::GraphOptimizationLevel;
use ort::value::Tensor;
use rustfft::{FftPlanner, num_complex::Complex};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::Instant;
use tokenizers::Tokenizer;

// Voxtral uses Whisper-compatible audio preprocessing with 128 mel bins.
const SAMPLE_RATE: u32 = 16000;
const N_FFT: usize = 400;
const HOP_LENGTH: usize = 160;
const N_MELS: usize = 128;
const CHUNK_SAMPLES: usize = 480_000; // 30 seconds at 16 kHz

pub const DEFAULT_MODEL_DIR: &str = "~/.local/share/lazyspeak/onnx";
pub const DEFAULT_VARIANT: &str = "_q4";

/// Paths to the three ONNX model components + tokenizer.
///
/// Expected directory layout (produced by `scripts/convert_model.py`):
/// ```text
/// <base>/
///   tokenizer.json
///   onnx/
///     audio_encoder<variant>.onnx
///     decoder_model_merged<variant>.onnx
///     embed_tokens<variant>.onnx
/// ```
pub struct OnnxTranscriberConfig {
    /// Directory containing the ONNX model files (the `onnx/` subdirectory).
    pub model_dir: PathBuf,
    /// Which quantisation variant to load (e.g. "", "_q4", "_fp16").
    pub variant: String,
    /// Path to `tokenizer.json`. Defaults to `<model_dir>/../tokenizer.json`.
    pub tokenizer_path: Option<PathBuf>,
}

/// ONNX-based speech transcriber.
///
/// Sessions require `&mut self` for `run()`, so we wrap them in `Mutex`
/// to satisfy the `Send + Sync` bound on `SpeechTranscriber`.
pub struct OnnxTranscriber {
    encoder: Mutex<Session>,
    decoder: Mutex<Session>,
    embed_tokens: Mutex<Session>,
    tokenizer: Tokenizer,
    mel_filters: Array2<f32>,
}

impl OnnxTranscriber {
    pub fn new(config: OnnxTranscriberConfig) -> Result<Self> {
        let suffix = &config.variant;
        let dir = &config.model_dir;

        let encoder = load_session(&dir.join(format!("audio_encoder{suffix}.onnx")))?;
        let decoder = load_session(&dir.join(format!("decoder_model_merged{suffix}.onnx")))?;
        let embed_tokens = load_session(&dir.join(format!("embed_tokens{suffix}.onnx")))?;

        let tokenizer_path = config
            .tokenizer_path
            .unwrap_or_else(|| dir.join("../tokenizer.json"));

        anyhow::ensure!(
            tokenizer_path.exists(),
            "tokenizer not found at {} — run scripts/convert_model.py first",
            tokenizer_path.display()
        );

        let tokenizer =
            Tokenizer::from_file(&tokenizer_path).map_err(|e| anyhow::anyhow!("{e}"))?;

        let mel_filters = mel_filterbank(N_MELS, N_FFT);

        Ok(Self {
            encoder: Mutex::new(encoder),
            decoder: Mutex::new(decoder),
            embed_tokens: Mutex::new(embed_tokens),
            tokenizer,
            mel_filters,
        })
    }

    /// Compute log-mel spectrogram from raw audio — Whisper-compatible preprocessing.
    /// Returns (shape, flat data) where shape is [1, N_MELS, n_frames].
    fn mel_spectrogram(&self, samples: &[f32]) -> (Vec<usize>, Vec<f32>) {
        // Pad or trim to chunk length
        let mut padded = vec![0.0f32; CHUNK_SAMPLES];
        let copy_len = samples.len().min(CHUNK_SAMPLES);
        padded[..copy_len].copy_from_slice(&samples[..copy_len]);

        // STFT
        let n_frames = (CHUNK_SAMPLES - N_FFT) / HOP_LENGTH + 1;
        let mut planner = FftPlanner::<f32>::new();
        let fft = planner.plan_fft_forward(N_FFT);

        let hann = hann_window(N_FFT);
        let n_freqs = N_FFT / 2 + 1;
        let mut magnitudes = Array2::<f32>::zeros((n_freqs, n_frames));

        let mut fft_buf = vec![Complex::new(0.0f32, 0.0f32); N_FFT];
        let mut scratch = vec![Complex::new(0.0f32, 0.0f32); fft.get_inplace_scratch_len()];

        for frame in 0..n_frames {
            let offset = frame * HOP_LENGTH;
            for i in 0..N_FFT {
                fft_buf[i] = Complex::new(padded[offset + i] * hann[i], 0.0);
            }
            fft.process_with_scratch(&mut fft_buf, &mut scratch);
            for i in 0..n_freqs {
                magnitudes[[i, frame]] = fft_buf[i].norm_sqr();
            }
        }

        // Apply mel filterbank, log-scale, normalise
        let mel = self.mel_filters.dot(&magnitudes);
        let log_spec = mel.mapv(|v| (v.max(1e-10)).log10());
        let max_val = log_spec.iter().cloned().fold(f32::NEG_INFINITY, f32::max);
        let normalised = log_spec.mapv(|v| ((v - max_val) * 4.0) + 4.0);

        // Flatten to [1, N_MELS, n_frames] in row-major order
        let shape = vec![1, N_MELS, n_frames];
        let data: Vec<f32> = normalised.into_raw_vec();
        (shape, data)
    }

    /// Greedy autoregressive decode from encoder hidden states.
    fn decode(&self, enc_shape: &[i64], enc_data: &[f32]) -> Result<String> {
        let bos_id: i64 = 1;
        let eos_id: i64 = 2;
        let max_new_tokens: usize = 448;

        let mut generated_ids: Vec<i64> = vec![bos_id];

        let mut decoder = self.decoder.lock().unwrap();
        let mut embed = self.embed_tokens.lock().unwrap();

        for _ in 0..max_new_tokens {
            let last_id = *generated_ids.last().unwrap();

            // Embed the last token
            let input_ids = Tensor::from_array(([1usize, 1], vec![last_id]))
                .map_err(|e| anyhow::anyhow!("input_ids tensor: {e}"))?;

            let embeddings = embed
                .run(ort::inputs![input_ids])
                .map_err(|e| anyhow::anyhow!("embed_tokens run: {e}"))?;

            let (_emb_shape, emb_data) = embeddings[0]
                .try_extract_tensor::<f32>()
                .map_err(|e| anyhow::anyhow!("extract embeds: {e}"))?;

            // Rebuild tensors for decoder (ort takes ownership)
            let enc_shape_vec: Vec<i64> = enc_shape.to_vec();
            let enc_tensor = Tensor::from_array((enc_shape_vec, enc_data.to_vec()))
                .map_err(|e| anyhow::anyhow!("enc tensor: {e}"))?;
            let emb_shape_vec: Vec<i64> = _emb_shape.to_vec();
            let embeds_tensor = Tensor::from_array((emb_shape_vec, emb_data.to_vec()))
                .map_err(|e| anyhow::anyhow!("embeds tensor: {e}"))?;

            // Run decoder
            let decoder_out = decoder
                .run(ort::inputs![embeds_tensor, enc_tensor])
                .map_err(|e| anyhow::anyhow!("decoder run: {e}"))?;

            let (logits_shape, logits_data) = decoder_out[0]
                .try_extract_tensor::<f32>()
                .map_err(|e| anyhow::anyhow!("extract logits: {e}"))?;

            // Greedy: argmax of last position
            let vocab_size = logits_shape[logits_shape.len() - 1] as usize;
            let seq_len = logits_shape[1] as usize;
            let last_start = (seq_len - 1) * vocab_size;
            let last_logits: &[f32] = &logits_data[last_start..last_start + vocab_size];

            let next_id = last_logits
                .iter()
                .enumerate()
                .max_by(|a, b| a.1.partial_cmp(b.1).unwrap())
                .map(|(i, _)| i as i64)
                .unwrap_or(eos_id);

            if next_id == eos_id {
                break;
            }
            generated_ids.push(next_id);
        }

        let token_ids: Vec<u32> = generated_ids.iter().map(|&id| id as u32).collect();
        let text = self
            .tokenizer
            .decode(&token_ids, true)
            .map_err(|e| anyhow::anyhow!("tokenizer decode failed: {e}"))?;

        Ok(text.trim().to_string())
    }
}

impl SpeechTranscriber for OnnxTranscriber {
    fn transcribe(&self, samples: &[f32], sample_rate: u32) -> Result<TranscribeResult> {
        anyhow::ensure!(
            sample_rate == SAMPLE_RATE,
            "ONNX backend requires {SAMPLE_RATE} Hz audio, got {sample_rate} Hz — resample before calling"
        );

        let start = Instant::now();

        // 1. Compute mel spectrogram
        let (mel_shape, mel_data) = self.mel_spectrogram(samples);

        // 2. Run audio encoder
        let mel_tensor = Tensor::from_array((mel_shape.as_slice(), mel_data))
            .map_err(|e| anyhow::anyhow!("mel tensor: {e}"))?;

        let mut enc = self.encoder.lock().unwrap();
        let encoder_out = enc
            .run(ort::inputs![mel_tensor])
            .map_err(|e| anyhow::anyhow!("encoder run: {e}"))?;

        let (enc_shape, enc_data) = encoder_out[0]
            .try_extract_tensor::<f32>()
            .map_err(|e| anyhow::anyhow!("extract encoder output: {e}"))?;

        let enc_shape_vec: Vec<i64> = enc_shape.to_vec();
        let enc_data_vec: Vec<f32> = enc_data.to_vec();
        drop(encoder_out);
        drop(enc);

        // 3. Autoregressive decode
        let text = self.decode(&enc_shape_vec, &enc_data_vec)?;

        Ok(TranscribeResult {
            text,
            duration_ms: start.elapsed().as_millis() as u64,
        })
    }

    fn is_ready(&self) -> bool {
        true // In-process — always ready once constructed
    }

    fn name(&self) -> &str {
        "onnx"
    }
}

// --- Audio preprocessing utilities ------------------------------------------

fn load_session(path: &Path) -> Result<Session> {
    let display = path.display().to_string();
    Session::builder()
        .map_err(|e| anyhow::anyhow!("session builder: {e}"))?
        .with_optimization_level(GraphOptimizationLevel::Level3)
        .map_err(|e| anyhow::anyhow!("optimization level: {e}"))?
        .with_intra_threads(4)
        .map_err(|e| anyhow::anyhow!("intra threads: {e}"))?
        .commit_from_file(path)
        .map_err(|e| anyhow::anyhow!("failed to load ONNX model {display}: {e}"))
}

/// Hann window of length `n`.
fn hann_window(n: usize) -> Vec<f32> {
    (0..n)
        .map(|i| 0.5 * (1.0 - (2.0 * std::f32::consts::PI * i as f32 / n as f32).cos()))
        .collect()
}

/// Triangular mel filterbank matrix [n_mels, n_fft/2 + 1].
fn mel_filterbank(n_mels: usize, n_fft: usize) -> Array2<f32> {
    let n_freqs = n_fft / 2 + 1;
    let f_max = SAMPLE_RATE as f32 / 2.0;

    let hz_to_mel = |f: f32| 2595.0 * (1.0 + f / 700.0).log10();
    let mel_to_hz = |m: f32| 700.0 * (10.0_f32.powf(m / 2595.0) - 1.0);

    let mel_min = hz_to_mel(0.0);
    let mel_max = hz_to_mel(f_max);

    let mel_points: Vec<f32> = (0..=n_mels + 1)
        .map(|i| mel_min + (mel_max - mel_min) * i as f32 / (n_mels + 1) as f32)
        .collect();
    let hz_points: Vec<f32> = mel_points.iter().map(|&m| mel_to_hz(m)).collect();
    let bin_points: Vec<f32> = hz_points
        .iter()
        .map(|&f| f * (n_fft as f32) / SAMPLE_RATE as f32)
        .collect();

    let mut filters = Array2::<f32>::zeros((n_mels, n_freqs));

    for m in 0..n_mels {
        let left = bin_points[m];
        let center = bin_points[m + 1];
        let right = bin_points[m + 2];

        for k in 0..n_freqs {
            let freq = k as f32;
            if freq >= left && freq <= center {
                filters[[m, k]] = (freq - left) / (center - left);
            } else if freq > center && freq <= right {
                filters[[m, k]] = (right - freq) / (right - center);
            }
        }
    }

    // Slaney normalisation
    for m in 0..n_mels {
        let enorm = 2.0 / (hz_points[m + 2] - hz_points[m]);
        for k in 0..n_freqs {
            filters[[m, k]] *= enorm;
        }
    }

    filters
}
