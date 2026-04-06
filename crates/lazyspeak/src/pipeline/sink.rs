use crate::protocol::{Event, State};
use streamsafe::{Result, Sink, StreamSafeError};

/// Terminal pipeline stage that sends transcript events to the unified
/// event channel, then emits an Idle status.
pub struct EventSink {
    event_tx: tokio::sync::mpsc::Sender<Event>,
}

impl EventSink {
    pub fn new(event_tx: tokio::sync::mpsc::Sender<Event>) -> Self {
        Self { event_tx }
    }
}

impl Sink for EventSink {
    type Input = Event;

    async fn consume(&mut self, input: Event) -> Result<()> {
        self.event_tx
            .send(input)
            .await
            .map_err(|_| StreamSafeError::ChannelClosed)?;
        self.event_tx
            .send(Event::Status { state: State::Idle })
            .await
            .map_err(|_| StreamSafeError::ChannelClosed)?;
        Ok(())
    }
}
