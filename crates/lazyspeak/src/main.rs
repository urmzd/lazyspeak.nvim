use std::io::{self, BufRead, Write};
use std::sync::Arc;

use anyhow::Result;
use lazyspeak::audio::{AudioCapture, AudioConfig};
use lazyspeak::pipeline::{AudioSource, EventSink, TranscribeTransform, VadFilter};
use lazyspeak::protocol::{Event, State, parse_command, serialize_event};
use lazyspeak::transcribe::SpeechTranscriber;
use streamsafe::PipelineBuilder;
use tokio_util::sync::CancellationToken;

/// Build the HTTP transcription backend from environment variables.
///
/// LAZYSPEAK_STT_URL — server URL (default http://127.0.0.1:8674)
fn build_transcriber() -> Result<Box<dyn SpeechTranscriber>> {
    use lazyspeak::transcribe::http::{DEFAULT_SERVER_URL, HttpTranscriber, HttpTranscriberConfig};
    let server_url =
        std::env::var("LAZYSPEAK_STT_URL").unwrap_or_else(|_| DEFAULT_SERVER_URL.to_string());
    let transcriber = HttpTranscriber::new(HttpTranscriberConfig { server_url });
    Ok(Box::new(transcriber))
}

/// Drains the event channel and writes JSON lines to stdout.
async fn stdout_writer(mut event_rx: tokio::sync::mpsc::Receiver<Event>) {
    let result: Result<()> = tokio::task::spawn_blocking(move || {
        let mut stdout = io::stdout().lock();
        while let Some(event) = event_rx.blocking_recv() {
            if let Ok(line) = serialize_event(&event) {
                if writeln!(stdout, "{line}").is_err() {
                    break;
                }
                if stdout.flush().is_err() {
                    break;
                }
            }
        }
        Ok(())
    })
    .await
    .unwrap_or(Ok(()));

    if let Err(e) = result {
        tracing::error!("stdout writer error: {e}");
    }
}

/// Reads stdin commands and controls audio capture + cancellation.
async fn stdin_command_loop(
    audio: Arc<AudioCapture>,
    event_tx: tokio::sync::mpsc::Sender<Event>,
    token: CancellationToken,
) {
    let _ = tokio::task::spawn_blocking(move || {
        let stdin = io::stdin().lock();
        for line in stdin.lines() {
            let line = match line {
                Ok(l) => l,
                Err(_) => break,
            };
            if line.trim().is_empty() {
                continue;
            }

            match parse_command(&line) {
                Ok(cmd) => match cmd {
                    lazyspeak::protocol::Command::StartListening => {
                        audio.set_listening(true);
                        let _ = event_tx.blocking_send(Event::Status {
                            state: State::Listening,
                        });
                    }
                    lazyspeak::protocol::Command::StopListening
                    | lazyspeak::protocol::Command::Cancel => {
                        audio.set_listening(false);
                        let _ = event_tx.blocking_send(Event::Status { state: State::Idle });
                    }
                    lazyspeak::protocol::Command::Shutdown => {
                        token.cancel();
                        break;
                    }
                },
                Err(e) => {
                    let _ = event_tx.blocking_send(Event::Error {
                        message: format!("invalid command: {e}"),
                    });
                }
            }
        }
    })
    .await;
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_writer(io::stderr)
        .with_env_filter("lazyspeak=debug")
        .init();

    // Unified event channel — all events flow through here to stdout.
    let (event_tx, event_rx) = tokio::sync::mpsc::channel::<Event>(64);

    // Initial status.
    let _ = event_tx.send(Event::Status { state: State::Idle }).await;

    // Transcription backend.
    let transcriber: Arc<dyn SpeechTranscriber> = Arc::from(build_transcriber()?);
    let stt_available = transcriber.is_ready();
    let backend_name = transcriber.name().to_string();
    if stt_available {
        tracing::info!("STT backend ready ({backend_name})");
    } else {
        tracing::warn!(
            "STT backend not ready ({backend_name}) — will emit placeholder transcripts"
        );
    }

    // Audio capture.
    let audio = Arc::new(AudioCapture::new(AudioConfig::default()));
    let device_sample_rate = audio.sample_rate();
    let sync_rx = audio.start()?;
    audio.set_listening(false);

    let token = CancellationToken::new();

    // Spawn stdout writer.
    let writer_handle = tokio::spawn(stdout_writer(event_rx));

    // Spawn stdin command handler.
    let stdin_handle = tokio::spawn(stdin_command_loop(
        audio.clone(),
        event_tx.clone(),
        token.clone(),
    ));

    // Build and run the pipeline.
    let pipeline_result = PipelineBuilder::from(AudioSource::new(sync_rx))
        .filter_pipe(VadFilter::new(event_tx.clone()))
        .pipe(TranscribeTransform::new(
            transcriber,
            device_sample_rate,
            stt_available,
            event_tx.clone(),
        ))
        .into(EventSink::new(event_tx))
        .run_with_token(token)
        .await;

    // Cleanup.
    audio.set_listening(false);
    let _ = stdin_handle.await;
    let _ = writer_handle.await;

    pipeline_result.map_err(|e| anyhow::anyhow!("{e}"))
}
