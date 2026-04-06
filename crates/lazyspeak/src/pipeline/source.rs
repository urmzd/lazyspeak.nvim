use lazyspeak_core::audio::AudioEvent;
use streamsafe::{Result, Source};

/// Bridges the synchronous `std::sync::mpsc::Receiver<AudioEvent>` from cpal
/// into an async streamsafe `Source`.
pub struct AudioSource {
    rx: tokio::sync::mpsc::Receiver<AudioEvent>,
}

impl AudioSource {
    pub fn new(sync_rx: std::sync::mpsc::Receiver<AudioEvent>) -> Self {
        let (tx, rx) = tokio::sync::mpsc::channel(64);
        std::thread::spawn(move || {
            for event in sync_rx {
                if tx.blocking_send(event).is_err() {
                    break;
                }
            }
        });
        Self { rx }
    }
}

impl Source for AudioSource {
    type Output = AudioEvent;

    async fn produce(&mut self) -> Result<Option<AudioEvent>> {
        Ok(self.rx.recv().await)
    }
}
