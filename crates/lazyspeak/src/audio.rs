//! Microphone capture and Voice Activity Detection.
//!
//! Uses `cpal` for cross-platform audio input. VAD is a simple energy-based
//! detector for now — will be replaced with silero-vad (ONNX) later.

use anyhow::{Context, Result};
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, mpsc};
use std::time::{Duration, Instant};

/// Configuration for audio capture.
pub struct AudioConfig {
    pub sample_rate: u32,
    pub channels: u16,
    pub vad_threshold: f32,
    pub silence_duration_ms: u64,
    pub max_duration_ms: u64,
}

impl Default for AudioConfig {
    fn default() -> Self {
        Self {
            sample_rate: 16000,
            channels: 1,
            vad_threshold: 0.01,
            silence_duration_ms: 1000,
            max_duration_ms: 30000,
        }
    }
}

/// Events emitted by the audio capture system.
pub enum AudioEvent {
    /// VAD detected speech start/stop.
    Vad(bool),
    /// A complete utterance was captured.
    Utterance { samples: Vec<f32>, duration_ms: u64 },
    /// An error occurred.
    Error(String),
}

/// Captures audio from the default input device with energy-based VAD.
pub struct AudioCapture {
    config: AudioConfig,
    listening: Arc<AtomicBool>,
    device_sample_rate: u32,
}

impl AudioCapture {
    pub fn new(config: AudioConfig) -> Self {
        let host = cpal::default_host();
        let sample_rate = host
            .default_input_device()
            .and_then(|d| d.default_input_config().ok())
            .map(|c| c.sample_rate().0)
            .unwrap_or(config.sample_rate);

        Self {
            config,
            listening: Arc::new(AtomicBool::new(false)),
            device_sample_rate: sample_rate,
        }
    }

    /// Returns the actual sample rate of the capture device.
    pub fn sample_rate(&self) -> u32 {
        self.device_sample_rate
    }

    /// Start capturing audio. Sends events through the returned receiver.
    /// Call `stop()` to end capture.
    pub fn start(&self) -> Result<mpsc::Receiver<AudioEvent>> {
        let (tx, rx) = mpsc::channel();

        let host = cpal::default_host();
        let device = host
            .default_input_device()
            .context("no input device available")?;

        let supported = device
            .default_input_config()
            .context("no supported input config")?;

        let stream_config = cpal::StreamConfig {
            channels: supported.channels().min(self.config.channels),
            sample_rate: supported.sample_rate(),
            buffer_size: cpal::BufferSize::Default,
        };

        let listening = self.listening.clone();
        let threshold = self.config.vad_threshold;
        let silence_dur = Duration::from_millis(self.config.silence_duration_ms);
        let max_dur = Duration::from_millis(self.config.max_duration_ms);
        let sample_rate = stream_config.sample_rate.0;
        let device_channels = stream_config.channels as usize;

        let state = Arc::new(Mutex::new(CaptureState::new()));

        let state_clone = state.clone();
        let tx_clone = tx.clone();

        let stream = device.build_input_stream(
            &stream_config,
            move |data: &[f32], _: &cpal::InputCallbackInfo| {
                if !listening.load(Ordering::Relaxed) {
                    return;
                }

                // Downmix to mono if device has multiple channels
                let mono: Vec<f32> = if device_channels > 1 {
                    data.chunks(device_channels)
                        .map(|frame| frame.iter().sum::<f32>() / device_channels as f32)
                        .collect()
                } else {
                    data.to_vec()
                };
                let data = &mono;

                let rms = (data.iter().map(|s| s * s).sum::<f32>() / data.len() as f32).sqrt();
                let is_speech = rms > threshold;

                let mut st = state_clone.lock().unwrap();

                // Detect speech start/stop transitions
                if is_speech && !st.was_speaking {
                    st.was_speaking = true;
                    st.speech_start = Some(Instant::now());
                    st.last_speech = Instant::now();
                    let _ = tx_clone.send(AudioEvent::Vad(true));
                } else if is_speech {
                    st.last_speech = Instant::now();
                }

                // Accumulate samples while speaking
                if st.was_speaking {
                    st.buffer.extend_from_slice(data);
                }

                // Check for silence timeout or max duration
                if st.was_speaking {
                    let since_speech = st.last_speech.elapsed();
                    let since_start = st
                        .speech_start
                        .map(|s| s.elapsed())
                        .unwrap_or(Duration::ZERO);

                    if since_speech >= silence_dur || since_start >= max_dur {
                        st.was_speaking = false;
                        let _ = tx_clone.send(AudioEvent::Vad(false));

                        let samples = std::mem::take(&mut st.buffer);
                        let duration_ms = (samples.len() as u64 * 1000) / sample_rate as u64;
                        let _ = tx_clone.send(AudioEvent::Utterance {
                            samples,
                            duration_ms,
                        });

                        st.speech_start = None;
                    }
                }
            },
            move |err| {
                let _ = tx.send(AudioEvent::Error(format!("audio stream error: {err}")));
            },
            None,
        )?;

        stream.play()?;
        // Leak the stream so it stays alive — stopped via the listening flag
        std::mem::forget(stream);

        self.listening.store(true, Ordering::Relaxed);

        Ok(rx)
    }

    pub fn set_listening(&self, active: bool) {
        self.listening.store(active, Ordering::Relaxed);
    }

    pub fn is_listening(&self) -> bool {
        self.listening.load(Ordering::Relaxed)
    }
}

struct CaptureState {
    buffer: Vec<f32>,
    was_speaking: bool,
    last_speech: Instant,
    speech_start: Option<Instant>,
}

impl CaptureState {
    fn new() -> Self {
        Self {
            buffer: Vec::new(),
            was_speaking: false,
            last_speech: Instant::now(),
            speech_start: None,
        }
    }
}
