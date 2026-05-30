//! JSON lines protocol for communicating with the Neovim plugin.

use serde::{Deserialize, Serialize};

#[derive(Debug, Deserialize)]
#[serde(tag = "cmd")]
pub enum Command {
    #[serde(rename = "start_listening")]
    StartListening,
    #[serde(rename = "stop_listening")]
    StopListening,
    #[serde(rename = "cancel")]
    Cancel,
    #[serde(rename = "shutdown")]
    Shutdown,
}

#[derive(Debug, Serialize)]
#[serde(tag = "type")]
pub enum Event {
    #[serde(rename = "status")]
    Status { state: State },
    #[serde(rename = "vad")]
    Vad { speaking: bool },
    /// An interim, non-final transcript emitted while the user is still
    /// speaking. Provisional — superseded by the final `Transcript`.
    #[serde(rename = "partial")]
    Partial { text: String },
    #[serde(rename = "transcript")]
    Transcript { text: String, duration_ms: u64 },
    #[serde(rename = "error")]
    Error { message: String },
}

#[derive(Debug, Serialize, Deserialize, Clone, Copy)]
#[serde(rename_all = "lowercase")]
pub enum State {
    Idle,
    Listening,
    Transcribing,
}

/// Read a command from a JSON line.
pub fn parse_command(line: &str) -> anyhow::Result<Command> {
    Ok(serde_json::from_str(line.trim())?)
}

/// Serialize an event to a JSON line.
pub fn serialize_event(event: &Event) -> anyhow::Result<String> {
    Ok(serde_json::to_string(event)?)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn partial_serializes_with_partial_tag() {
        let line = serialize_event(&Event::Partial {
            text: "hello".into(),
        })
        .unwrap();
        assert_eq!(line, r#"{"type":"partial","text":"hello"}"#);
    }

    #[test]
    fn transcript_carries_duration() {
        let line = serialize_event(&Event::Transcript {
            text: "done".into(),
            duration_ms: 42,
        })
        .unwrap();
        assert_eq!(
            line,
            r#"{"type":"transcript","text":"done","duration_ms":42}"#
        );
    }
}
