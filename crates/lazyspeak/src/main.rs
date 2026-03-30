use anyhow::Result;
use lazyspeak_core::audio::{AudioCapture, AudioConfig, AudioEvent};
use lazyspeak_core::protocol::{parse_command, serialize_event, Command, Event, State};
use lazyspeak_core::transcribe::SpeechTranscriber;
use std::io::{self, BufRead, Write};
use std::path::PathBuf;
use std::sync::mpsc;
use std::thread;

fn emit(event: &Event) -> Result<()> {
    let line = serialize_event(event)?;
    let mut stdout = io::stdout().lock();
    writeln!(stdout, "{line}")?;
    stdout.flush()?;
    Ok(())
}

/// Build the appropriate transcription backend from environment variables.
///
/// LAZYSPEAK_BACKEND     — "http" (default) or "onnx"
/// LAZYSPEAK_STT_URL     — server URL for the http backend
/// LAZYSPEAK_MODEL_DIR   — ONNX model directory for the onnx backend
/// LAZYSPEAK_MODEL_VARIANT — ONNX quantisation suffix (default "_q4")
fn build_transcriber() -> Result<Box<dyn SpeechTranscriber>> {
    let backend = std::env::var("LAZYSPEAK_BACKEND").unwrap_or_else(|_| "http".to_string());

    match backend.as_str() {
        #[cfg(feature = "http")]
        "http" => {
            use lazyspeak_core::transcribe::http::{
                HttpTranscriber, HttpTranscriberConfig, DEFAULT_SERVER_URL,
            };
            let server_url = std::env::var("LAZYSPEAK_STT_URL")
                .unwrap_or_else(|_| DEFAULT_SERVER_URL.to_string());
            let transcriber = HttpTranscriber::new(HttpTranscriberConfig { server_url });
            Ok(Box::new(transcriber))
        }
        #[cfg(feature = "onnx")]
        "onnx" => {
            use lazyspeak_core::transcribe::onnx::{
                OnnxTranscriber, OnnxTranscriberConfig, DEFAULT_MODEL_DIR, DEFAULT_VARIANT,
            };
            let model_dir = std::env::var("LAZYSPEAK_MODEL_DIR")
                .unwrap_or_else(|_| shellexpand::tilde(DEFAULT_MODEL_DIR).to_string());
            let variant = std::env::var("LAZYSPEAK_MODEL_VARIANT")
                .unwrap_or_else(|_| DEFAULT_VARIANT.to_string());
            let tokenizer_path = std::env::var("LAZYSPEAK_TOKENIZER_PATH")
                .ok()
                .map(PathBuf::from);
            let transcriber = OnnxTranscriber::new(OnnxTranscriberConfig {
                model_dir: model_dir.into(),
                variant,
                tokenizer_path,
            })?;
            Ok(Box::new(transcriber))
        }
        other => anyhow::bail!("unknown backend: {other} (expected \"http\" or \"onnx\")"),
    }
}

fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_writer(io::stderr)
        .with_env_filter("lazyspeak=debug")
        .init();

    emit(&Event::Status { state: State::Idle })?;

    let transcriber = build_transcriber()?;

    let backend_name = transcriber.name();
    let stt_available = transcriber.is_ready();
    if stt_available {
        tracing::info!("STT backend ready ({backend_name})");
    } else {
        tracing::warn!("STT backend not ready ({backend_name}) — will emit placeholder transcripts");
    }

    let audio = AudioCapture::new(AudioConfig::default());
    let device_sample_rate = audio.sample_rate();
    let audio_rx = audio.start()?;
    audio.set_listening(false);

    // Audio event handler thread
    let (done_tx, done_rx) = mpsc::channel::<()>();
    thread::spawn(move || {
        for event in audio_rx {
            let result = match event {
                AudioEvent::Vad(speaking) => emit(&Event::Vad { speaking }),
                AudioEvent::Utterance {
                    samples,
                    duration_ms,
                } => {
                    let _ = emit(&Event::Status {
                        state: State::Transcribing,
                    });

                    let text = if stt_available {
                        match transcriber.transcribe(&samples, device_sample_rate) {
                            Ok(r) => r.text,
                            Err(e) => {
                                let _ = emit(&Event::Error {
                                    message: format!("transcription failed: {e}"),
                                });
                                format!("[transcription error: {e}]")
                            }
                        }
                    } else {
                        format!("[audio {duration_ms}ms — STT backend not available]")
                    };

                    let _ = emit(&Event::Transcript {
                        text,
                        duration_ms,
                    });
                    emit(&Event::Status { state: State::Idle })
                }
                AudioEvent::Error(msg) => emit(&Event::Error { message: msg }),
            };
            if result.is_err() {
                break;
            }
        }
        let _ = done_tx.send(());
    });

    // Command loop on stdin
    let stdin = io::stdin().lock();
    for line in stdin.lines() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }

        match parse_command(&line) {
            Ok(cmd) => match cmd {
                Command::StartListening => {
                    audio.set_listening(true);
                    emit(&Event::Status {
                        state: State::Listening,
                    })?;
                }
                Command::StopListening => {
                    audio.set_listening(false);
                    emit(&Event::Status { state: State::Idle })?;
                }
                Command::Cancel => {
                    audio.set_listening(false);
                    emit(&Event::Status { state: State::Idle })?;
                }
                Command::Shutdown => break,
            },
            Err(e) => {
                emit(&Event::Error {
                    message: format!("invalid command: {e}"),
                })?;
            }
        }
    }

    audio.set_listening(false);
    let _ = done_rx.recv_timeout(std::time::Duration::from_secs(1));

    Ok(())
}
