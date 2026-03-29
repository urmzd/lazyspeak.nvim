//! Speech-to-text via Voxtral Mini 3B (HTTP to llama-server).
//!
//! Sends captured audio to a local llama-server instance for transcription.
//! The server should be running with a Voxtral GGUF model loaded.

use anyhow::{Context, Result};
use reqwest::blocking::Client;
use serde::{Deserialize, Serialize};
use std::io::Cursor;
use std::time::Instant;

/// Configuration for the transcription backend.
pub struct TranscriberConfig {
    pub server_url: String,
}

impl Default for TranscriberConfig {
    fn default() -> Self {
        Self {
            server_url: "http://127.0.0.1:8674".to_string(),
        }
    }
}

pub struct Transcriber {
    config: TranscriberConfig,
    client: Client,
}

/// Response from the transcription endpoint.
#[derive(Debug, Deserialize)]
struct TranscriptionResponse {
    text: String,
}

/// Chat completion message for audio input.
#[derive(Debug, Serialize)]
struct ChatMessage {
    role: String,
    content: Vec<ChatContent>,
}

#[derive(Debug, Serialize)]
#[serde(tag = "type")]
enum ChatContent {
    #[serde(rename = "text")]
    Text { text: String },
    #[serde(rename = "input_audio")]
    Audio { input_audio: AudioData },
}

#[derive(Debug, Serialize)]
struct AudioData {
    data: String,
    format: String,
}

#[derive(Debug, Serialize)]
struct ChatRequest {
    model: String,
    messages: Vec<ChatMessage>,
}

#[derive(Debug, Deserialize)]
struct ChatResponse {
    choices: Vec<ChatChoice>,
}

#[derive(Debug, Deserialize)]
struct ChatChoice {
    message: ChatMessageResponse,
}

#[derive(Debug, Deserialize)]
struct ChatMessageResponse {
    content: String,
}

impl Transcriber {
    pub fn new(config: TranscriberConfig) -> Self {
        Self {
            config,
            client: Client::builder()
                .timeout(std::time::Duration::from_secs(30))
                .build()
                .expect("failed to build HTTP client"),
        }
    }

    /// Transcribe audio samples (f32, mono) to text.
    /// Tries the OpenAI-compatible /v1/audio/transcriptions endpoint first,
    /// falls back to /v1/chat/completions with audio content.
    pub fn transcribe(&self, samples: &[f32], sample_rate: u32) -> Result<TranscribeResult> {
        let start = Instant::now();

        // Convert f32 samples to WAV bytes for the transcription endpoint
        let wav_bytes = encode_wav(samples, sample_rate)?;

        // Try /v1/audio/transcriptions first (standard OpenAI-compatible endpoint)
        let result = self.try_transcription_endpoint(&wav_bytes);
        if let Ok(text) = result {
            return Ok(TranscribeResult {
                text,
                duration_ms: start.elapsed().as_millis() as u64,
            });
        }

        // Fallback: /v1/chat/completions with audio content
        let text = self.try_chat_endpoint(&wav_bytes)?;
        Ok(TranscribeResult {
            text,
            duration_ms: start.elapsed().as_millis() as u64,
        })
    }

    fn try_transcription_endpoint(&self, wav_bytes: &[u8]) -> Result<String> {
        let url = format!("{}/v1/audio/transcriptions", self.config.server_url);

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

        let body: TranscriptionResponse = resp.json().context("failed to parse transcription response")?;
        Ok(body.text.trim().to_string())
    }

    fn try_chat_endpoint(&self, wav_bytes: &[u8]) -> Result<String> {
        let url = format!("{}/v1/chat/completions", self.config.server_url);

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

    /// Check if the transcription server is reachable.
    pub fn health_check(&self) -> bool {
        let url = format!("{}/health", self.config.server_url);
        self.client.get(&url).send().is_ok()
    }
}

pub struct TranscribeResult {
    pub text: String,
    pub duration_ms: u64,
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
