use std::sync::Arc;

use lazyspeak_core::protocol::Event;
use lazyspeak_core::transcribe::SpeechTranscriber;
use streamsafe::{Result, StreamSafeError, Transform};

use super::filter::UtteranceData;

/// Transcribes utterance audio into text via the STT backend.
///
/// Uses `spawn_blocking` because `SpeechTranscriber::transcribe` is synchronous.
pub struct TranscribeTransform {
    transcriber: Arc<dyn SpeechTranscriber>,
    sample_rate: u32,
    stt_available: bool,
    event_tx: tokio::sync::mpsc::Sender<Event>,
}

impl TranscribeTransform {
    pub fn new(
        transcriber: Arc<dyn SpeechTranscriber>,
        sample_rate: u32,
        stt_available: bool,
        event_tx: tokio::sync::mpsc::Sender<Event>,
    ) -> Self {
        Self {
            transcriber,
            sample_rate,
            stt_available,
            event_tx,
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
        let event_tx = self.event_tx.clone();

        let event = tokio::task::spawn_blocking(move || {
            if stt_available {
                match transcriber.transcribe(&input.samples, sample_rate) {
                    Ok(r) => Event::Transcript {
                        text: r.text,
                        duration_ms,
                    },
                    Err(e) => {
                        let _ = event_tx.blocking_send(Event::Error {
                            message: format!("transcription failed: {e}"),
                        });
                        Event::Transcript {
                            text: format!("[transcription error: {e}]"),
                            duration_ms,
                        }
                    }
                }
            } else {
                Event::Transcript {
                    text: format!("[audio {duration_ms}ms — STT backend not available]"),
                    duration_ms,
                }
            }
        })
        .await
        .map_err(StreamSafeError::other)?;

        Ok(event)
    }
}
