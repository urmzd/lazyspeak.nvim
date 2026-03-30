//! HTTP transcription backend.
//!
//! Delegates STT to an external server (llama-server, vLLM, etc.) over
//! OpenAI-compatible HTTP endpoints.

use super::{SpeechTranscriber, TranscribeResult};
use anyhow::{Context, Result};
use reqwest::blocking::Client;
use serde::{Deserialize, Serialize};
use std::io::Cursor;
use std::time::Instant;

pub const DEFAULT_SERVER_URL: &str = "http://127.0.0.1:8674";

pub struct HttpTranscriberConfig {
    pub server_url: String,
}

pub struct HttpTranscriber {
    server_url: String,
    client: Client,
}

impl HttpTranscriber {
    pub fn new(config: HttpTranscriberConfig) -> Self {
        Self {
            server_url: config.server_url,
            client: Client::builder()
                .timeout(std::time::Duration::from_secs(30))
                .build()
                .expect("failed to build HTTP client"),
        }
    }

    /// Try the OpenAI-compatible /v1/audio/transcriptions endpoint.
    fn try_transcription_endpoint(&self, wav_bytes: &[u8]) -> Result<String> {
        let url = format!("{}/v1/audio/transcriptions", self.server_url);

        let form = reqwest::blocking::multipart::Form::new()
            .text("model", "voxtral")
            .part(
                "file",
                reqwest::blocking::multipart::Part::bytes(wav_bytes.to_vec())
                    .file_name("audio.wav")
                    .mime_str("audio/wav")?,
            );

        let resp = self
            .client
            .post(&url)
            .multipart(form)
            .send()
            .context("transcription endpoint request failed")?;

        if !resp.status().is_success() {
            anyhow::bail!("transcription endpoint returned {}", resp.status());
        }

        let body: TranscriptionResponse =
            resp.json().context("failed to parse transcription response")?;
        Ok(body.text.trim().to_string())
    }

    /// Fallback: /v1/chat/completions with base64-encoded audio.
    fn try_chat_endpoint(&self, wav_bytes: &[u8]) -> Result<String> {
        let url = format!("{}/v1/chat/completions", self.server_url);

        use base64::Engine;
        let audio_b64 = base64::engine::general_purpose::STANDARD.encode(wav_bytes);

        let request = ChatRequest {
            model: "voxtral".to_string(),
            messages: vec![ChatMessage {
                role: "user".to_string(),
                content: vec![
                    ChatContent::Text {
                        text: "Transcribe the following audio exactly as spoken.".to_string(),
                    },
                    ChatContent::Audio {
                        input_audio: AudioData {
                            data: audio_b64,
                            format: "wav".to_string(),
                        },
                    },
                ],
            }],
        };

        let resp = self
            .client
            .post(&url)
            .json(&request)
            .send()
            .context("chat endpoint request failed")?;

        if !resp.status().is_success() {
            let status = resp.status();
            let body = resp.text().unwrap_or_default();
            anyhow::bail!("chat endpoint returned {status}: {body}");
        }

        let body: ChatResponse = resp.json().context("failed to parse chat response")?;
        let text = body
            .choices
            .first()
            .map(|c| c.message.content.trim().to_string())
            .unwrap_or_default();

        Ok(text)
    }
}

impl SpeechTranscriber for HttpTranscriber {
    fn transcribe(&self, samples: &[f32], sample_rate: u32) -> Result<TranscribeResult> {
        let start = Instant::now();
        let wav_bytes = encode_wav(samples, sample_rate)?;

        // Try dedicated transcription endpoint first, fall back to chat
        let text = self
            .try_transcription_endpoint(&wav_bytes)
            .or_else(|_| self.try_chat_endpoint(&wav_bytes))?;

        Ok(TranscribeResult {
            text,
            duration_ms: start.elapsed().as_millis() as u64,
        })
    }

    fn is_ready(&self) -> bool {
        let url = format!("{}/health", self.server_url);
        self.client.get(&url).send().is_ok()
    }

    fn name(&self) -> &str {
        "http"
    }
}

// --- Wire types (private) ---------------------------------------------------

#[derive(Deserialize)]
struct TranscriptionResponse {
    text: String,
}

#[derive(Serialize)]
struct ChatMessage {
    role: String,
    content: Vec<ChatContent>,
}

#[derive(Serialize)]
#[serde(tag = "type")]
enum ChatContent {
    #[serde(rename = "text")]
    Text { text: String },
    #[serde(rename = "input_audio")]
    Audio { input_audio: AudioData },
}

#[derive(Serialize)]
struct AudioData {
    data: String,
    format: String,
}

#[derive(Serialize)]
struct ChatRequest {
    model: String,
    messages: Vec<ChatMessage>,
}

#[derive(Deserialize)]
struct ChatResponse {
    choices: Vec<ChatChoice>,
}

#[derive(Deserialize)]
struct ChatChoice {
    message: ChatMessageResponse,
}

#[derive(Deserialize)]
struct ChatMessageResponse {
    content: String,
}

/// Encode f32 samples as a WAV file in memory.
fn encode_wav(samples: &[f32], sample_rate: u32) -> Result<Vec<u8>> {
    let mut buf = Vec::new();
    let mut cursor = Cursor::new(&mut buf);

    let spec = hound::WavSpec {
        channels: 1,
        sample_rate,
        bits_per_sample: 16,
        sample_format: hound::SampleFormat::Int,
    };

    let mut writer = hound::WavWriter::new(&mut cursor, spec)?;
    for &sample in samples {
        let s16 = (sample * 32767.0).clamp(-32768.0, 32767.0) as i16;
        writer.write_sample(s16)?;
    }
    writer.finalize()?;

    Ok(buf)
}
