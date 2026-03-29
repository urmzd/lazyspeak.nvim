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
