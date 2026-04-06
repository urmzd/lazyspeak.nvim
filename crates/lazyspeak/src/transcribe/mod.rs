//! Speech-to-text transcription backends.
//!
//! Defines the `SpeechTranscriber` trait — the single abstraction that
//! decouples the daemon from any particular inference runtime.
//!
//! Backend:
//! - `http`  — delegates to an external server (llama-server, vLLM, etc.)

#[cfg(feature = "http")]
pub mod http;

use anyhow::Result;

/// Result of a transcription.
pub struct TranscribeResult {
    pub text: String,
    pub duration_ms: u64,
}

/// Contract that every STT backend must fulfil.
///
/// Implementations are expected to be long-lived — created once at startup
/// and called repeatedly for the lifetime of the daemon.
pub trait SpeechTranscriber: Send + Sync {
    /// Transcribe mono f32 audio samples into text.
    ///
    /// Implementations may require a specific `sample_rate` (e.g. 16 kHz)
    /// and must return `Err` if the rate is unsupported rather than
    /// silently producing bad output.
    fn transcribe(&self, samples: &[f32], sample_rate: u32) -> Result<TranscribeResult>;

    /// Non-blocking liveness check — returns `true` when the backend is ready.
    fn is_ready(&self) -> bool;

    /// Human-readable name for logging.
    fn name(&self) -> &str;
}
