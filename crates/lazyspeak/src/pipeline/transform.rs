use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use crate::protocol::Event;
use crate::transcribe::SpeechTranscriber;
use streamsafe::{Result, StreamSafeError, Transform};

use super::filter::UtteranceData;

/// Transcribes utterance audio into text via the STT backend.
///
/// Final utterances become `Event::Transcript`; interim snapshots become
/// `Event::Partial`. After each transcription the shared `partial_gate` is
/// cleared so the capture loop may emit the next partial (single-in-flight).
///
/// A failure never becomes a `Transcript`. Emitting placeholder text like
/// `[audio 412ms — STT backend not available]` as if the user had said it made
/// the plugin snapshot the working tree and prompt the agent with the error
/// string; failures are `Event::Error` so the host can treat them as such.
///
/// Uses `spawn_blocking` because `SpeechTranscriber::transcribe` is synchronous.
pub struct TranscribeTransform {
    transcriber: Arc<dyn SpeechTranscriber>,
    sample_rate: u32,
    stt_available: bool,
    partial_gate: Arc<AtomicBool>,
}

impl TranscribeTransform {
    pub fn new(
        transcriber: Arc<dyn SpeechTranscriber>,
        sample_rate: u32,
        stt_available: bool,
        partial_gate: Arc<AtomicBool>,
    ) -> Self {
        Self {
            transcriber,
            sample_rate,
            stt_available,
            partial_gate,
        }
    }
}

impl Transform for TranscribeTransform {
    type Input = UtteranceData;
    type Output = Event;

    async fn apply(&mut self, input: UtteranceData) -> Result<Event> {
        let transcriber = self.transcriber.clone();
        let sample_rate = self.sample_rate;
        let stt_available = self.stt_available;
        let duration_ms = input.duration_ms;
        let is_final = input.is_final;
        let partial_gate = self.partial_gate.clone();

        let event = tokio::task::spawn_blocking(move || {
            // Always release the gate when this transcription finishes, however
            // it finishes, so the capture loop is never permanently blocked.
            let _release = GateGuard(&partial_gate);

            if !stt_available {
                return if is_final {
                    Event::Error {
                        message: format!(
                            "STT backend unavailable, discarded {duration_ms}ms of audio \
                             (is llama-server reachable?)"
                        ),
                    }
                } else {
                    Event::Partial {
                        text: String::new(),
                    }
                };
            }

            match transcriber.transcribe(&input.samples, sample_rate) {
                Ok(r) if is_final => Event::Transcript {
                    text: r.text,
                    duration_ms,
                },
                Ok(r) => Event::Partial { text: r.text },
                Err(e) if is_final => Event::Error {
                    message: format!("transcription failed: {e}"),
                },
                // Swallow partial errors quietly — the final pass will report.
                Err(_) => Event::Partial {
                    text: String::new(),
                },
            }
        })
        .await
        .map_err(StreamSafeError::other)?;

        Ok(event)
    }
}

/// Clears the partial gate on drop, regardless of how transcription ends.
struct GateGuard<'a>(&'a AtomicBool);

impl Drop for GateGuard<'_> {
    fn drop(&mut self) {
        self.0.store(false, Ordering::Relaxed);
    }
}
