use lazyspeak_core::audio::AudioEvent;
use lazyspeak_core::protocol::{Event, State};
use streamsafe::{FilterTransform, Result};

/// Data extracted from an utterance, passed downstream for transcription.
pub struct UtteranceData {
    pub samples: Vec<f32>,
    pub duration_ms: u64,
}

/// Filters the audio event stream: emits VAD/error events as side-effects
/// to the event channel and passes only utterances through the pipeline.
pub struct VadFilter {
    event_tx: tokio::sync::mpsc::Sender<Event>,
}

impl VadFilter {
    pub fn new(event_tx: tokio::sync::mpsc::Sender<Event>) -> Self {
        Self { event_tx }
    }
}

impl FilterTransform for VadFilter {
    type Input = AudioEvent;
    type Output = UtteranceData;

    async fn apply(&mut self, input: AudioEvent) -> Result<Option<UtteranceData>> {
        match input {
            AudioEvent::Vad(speaking) => {
                let _ = self.event_tx.send(Event::Vad { speaking }).await;
                Ok(None)
            }
            AudioEvent::Utterance {
                samples,
                duration_ms,
            } => {
                let _ = self
                    .event_tx
                    .send(Event::Status {
                        state: State::Transcribing,
                    })
                    .await;
                Ok(Some(UtteranceData {
                    samples,
                    duration_ms,
                }))
            }
            AudioEvent::Error(msg) => {
                let _ = self.event_tx.send(Event::Error { message: msg }).await;
                Ok(None)
            }
        }
    }
}
