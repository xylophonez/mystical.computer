//! Audio decoding using symphonia - a pure-Rust multi-format audio decoder.
//!
//! symphonia decodes WAV, MP3, OGG (Vorbis), FLAC, AAC, M4A, WebM, and more
//! entirely in-process. No subprocess, no external dependencies beyond the codec
//! crates themselves. The decoded PCM is converted to mono f32 samples and passed
//! directly to whisper-rs for inference.

use std::sync::Mutex;

use symphonia::core::audio::{AudioBufferRef, Signal};
use symphonia::core::codecs::DecoderOptions;
use symphonia::core::formats::FormatOptions;
use symphonia::core::io::MediaSourceStream;
use symphonia::core::io::MediaSourceStreamOptions;
use symphonia::core::meta::MetadataOptions;
use symphonia::core::probe::Hint;

use crate::logging::log_message;

/// Global model - loaded once via init_whisper().
struct LoadedModel {
    path: String,
    ctx: whisper_rs::WhisperContext,
}

static CONTEXT: Mutex<Option<LoadedModel>> = Mutex::new(None);

/// Initialize (load) the whisper model from the given GGML file path.
pub fn init_model(model_path: &str) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let mut guard = CONTEXT.lock().map_err(|e| format!("mutex error: {}", e))?;
    if let Some(loaded) = guard.as_ref() {
        if loaded.path == model_path {
            log_message(
                "DEBUG",
                file!(),
                line!(),
                &format!("init_whisper: already loaded {}", model_path),
            );
            return Ok(());
        }
    }

    log_message(
        "INFO",
        file!(),
        line!(),
        &format!("init_whisper: model={}", model_path),
    );
    let ctx = whisper_rs::WhisperContext::new_with_params(
        model_path,
        whisper_rs::WhisperContextParameters::default(),
    )?;
    *guard = Some(LoadedModel {
        path: model_path.to_string(),
        ctx,
    });
    log_message("INFO", file!(), line!(), "Whisper model loaded and cached");
    Ok(())
}

/// Free the loaded model.
pub fn free_model() {
    if let Ok(mut guard) = CONTEXT.lock() {
        *guard = None;
        log_message("INFO", file!(), line!(), "Whisper model freed");
    }
}

/// Run full transcription pipeline: decode audio in Rust, then run whisper inference.
pub fn run_transcribe(
    audio_bytes: Vec<u8>,
    language: &str,
) -> Result<String, Box<dyn std::error::Error + Send + Sync>> {
    // 1. Decode audio to mono f32 samples using symphonia
    let samples = decode_audio(audio_bytes)?;

    // 2. Get the whisper context
    let ctx_guard = CONTEXT.lock().map_err(|e| format!("mutex error: {}", e))?;
    let loaded = ctx_guard
        .as_ref()
        .ok_or("whisper model not loaded - call init_whisper/1 first")?;

    // 3. Build FullParams
    let mut params =
        whisper_rs::FullParams::new(whisper_rs::SamplingStrategy::Greedy { best_of: 5 });
    if !language.is_empty() && language != "auto" {
        params.set_language(Some(language));
    }
    let threads = whisper_threads();
    params.set_n_threads(threads);
    log_message(
        "DEBUG",
        file!(),
        line!(),
        &format!("whisper inference threads={}", threads),
    );
    params.set_translate(false);
    params.set_print_special(false);
    params.set_print_progress(false);
    params.set_print_realtime(false);
    params.set_print_timestamps(false);

    // 4. Run inference
    let mut state = loaded.ctx.create_state()?;
    state.full(params, &samples)?;

    // 5. Collect results
    let n_segments = state.full_n_segments();
    let mut segments: Vec<serde_json::Value> = Vec::with_capacity(n_segments as usize);
    let mut full_text = String::new();

    for i in 0..n_segments {
        if let Some(seg) = state.get_segment(i) {
            let text = seg.to_str().unwrap_or("").to_string();
            if !full_text.is_empty() {
                full_text.push(' ');
            }
            full_text.push_str(&text);

            segments.push(serde_json::json!({
                "text": text,
                "timestamps": {
                    "begin": seg.start_timestamp() as f64 / 100.0,
                    "end": seg.end_timestamp() as f64 / 100.0
                }
            }));
        }
    }

    let detected_lang = if language.is_empty() || language == "auto" {
        if n_segments > 0 {
            "auto".to_string()
        } else {
            "en".to_string()
        }
    } else {
        language.to_string()
    };

    let result = serde_json::json!({
        "transcript": full_text,
        "language": detected_lang,
        "segments": segments
    });

    serde_json::to_string(&result)
        .map_err(|e| Box::new(e) as Box<dyn std::error::Error + Send + Sync>)
}

fn whisper_threads() -> i32 {
    if let Ok(raw) = std::env::var("WHISPER_THREADS") {
        if let Ok(parsed) = raw.parse::<usize>() {
            if parsed > 0 {
                return parsed.min(i32::MAX as usize) as i32;
            }
        }
    }

    std::thread::available_parallelism()
        .map(|parallelism| parallelism.get().max(1).min(i32::MAX as usize) as i32)
        .unwrap_or(1)
}

/// Decode raw audio bytes to a mono f32 vector using symphonia.
fn decode_audio(
    audio_bytes: Vec<u8>,
) -> Result<Vec<f32>, Box<dyn std::error::Error + Send + Sync>> {
    let mss = MediaSourceStream::new(
        Box::new(std::io::Cursor::new(audio_bytes)),
        MediaSourceStreamOptions::default(),
    );

    let mut hint = Hint::new();
    hint.with_extension("mp3");
    hint.with_extension("wav");
    hint.with_extension("ogg");
    hint.with_extension("flac");
    hint.with_extension("m4a");
    hint.with_extension("aac");
    hint.with_extension("webm");
    hint.with_extension("opus");

    let probed = symphonia::default::get_probe()
        .format(
            &hint,
            mss,
            &FormatOptions::default(),
            &MetadataOptions::default(),
        )
        .map_err(|e| format!("unsupported audio format: {}", e))?;

    let mut format = probed.format;
    let track = format
        .default_track()
        .ok_or("no audio track found")?
        .clone();

    let sample_rate = track.codec_params.sample_rate.unwrap_or(16000) as f32;
    let channels = track.codec_params.channels.map(|c| c.count()).unwrap_or(1);

    log_message(
        "DEBUG",
        file!(),
        line!(),
        &format!(
            "symphonia: codec={} {}Hz channels={}",
            track.codec_params.codec, sample_rate, channels
        ),
    );

    let mut decoder = symphonia::default::get_codecs()
        .make(&track.codec_params, &DecoderOptions::default())
        .map_err(|e| format!("failed to create decoder: {}", e))?;

    let mut all_samples: Vec<f32> = Vec::new();

    loop {
        match format.next_packet() {
            Ok(packet) if packet.track_id() == track.id => match decoder.decode(&packet) {
                Ok(decoded) => {
                    let mono = to_mono_f32(decoded, channels);
                    all_samples.extend(mono);
                }
                Err(symphonia::core::errors::Error::DecodeError(_)) => continue,
                Err(e) => {
                    log_message("WARN", file!(), line!(), &format!("decode error: {}", e));
                    break;
                }
            },
            Ok(_) => continue,
            Err(symphonia::core::errors::Error::IoError(_)) => break,
            Err(e) => return Err(format!("format error: {}", e).into()),
        }
    }

    // Resample to 16kHz if needed (whisper expects 16kHz)
    let target_rate = 16000_f32;
    if (sample_rate - target_rate).abs() > 0.1 {
        log_message(
            "DEBUG",
            file!(),
            line!(),
            &format!("resampling {} -> {}", sample_rate, target_rate),
        );
        all_samples = resample(&all_samples, sample_rate, target_rate);
    }

    log_message(
        "DEBUG",
        file!(),
        line!(),
        &format!(
            "decoded {} samples at {} Hz",
            all_samples.len(),
            target_rate
        ),
    );

    Ok(all_samples)
}

/// Convert any AudioBufferRef to a mono f32 Vec.
fn to_mono_f32(buffer: AudioBufferRef<'_>, channels: usize) -> Vec<f32> {
    match buffer {
        AudioBufferRef::U8(buf) => buf
            .chan(0)
            .iter()
            .map(|&s| (s as f32 - 128.0) / 128.0)
            .collect(),
        AudioBufferRef::S8(buf) => buf.chan(0).iter().map(|&s| s as f32 / 128.0).collect(),
        AudioBufferRef::U16(buf) => buf.chan(0).iter().map(|&s| s as f32 / 65535.0).collect(),
        // u24/i24 are u32/i32 newtype wrappers - extract 24 bits via masking
        AudioBufferRef::U24(buf) => buf
            .chan(0)
            .iter()
            .map(|s| (s.0 & 0x00FFFFFF_u32) as f32 / 16777216.0)
            .collect(),
        AudioBufferRef::U32(buf) => buf
            .chan(0)
            .iter()
            .map(|&s| s as f32 / 4294967295.0)
            .collect(),
        AudioBufferRef::S16(buf) => buf.chan(0).iter().map(|&s| s as f32 / 32768.0).collect(),
        AudioBufferRef::S24(buf) => buf
            .chan(0)
            .iter()
            .map(|s| {
                let bits = (s.0 as u32) & 0x00FFFFFF_u32;
                let val = if bits & 0x800000 != 0 {
                    (bits as i32) | !0x7FFFFF_i32
                } else {
                    bits as i32
                };
                val as f32 / 8388608.0
            })
            .collect(),
        AudioBufferRef::S32(buf) => buf
            .chan(0)
            .iter()
            .map(|&s| s as f32 / 2147483648.0)
            .collect(),
        AudioBufferRef::F32(buf) => {
            if channels > 1 {
                let n = buf.frames();
                (0..n)
                    .map(|i| (0..channels).map(|c| buf.chan(c)[i]).sum::<f32>() / channels as f32)
                    .collect()
            } else {
                buf.chan(0).to_vec()
            }
        }
        AudioBufferRef::F64(buf) => buf.chan(0).iter().map(|&s| s as f32).collect(),
    }
}

/// Linear interpolation resampling.
fn resample(samples: &[f32], from_rate: f32, to_rate: f32) -> Vec<f32> {
    if samples.is_empty() {
        return vec![];
    }
    let ratio = from_rate / to_rate;
    let new_len = ((samples.len() as f32) / ratio).ceil() as usize;
    let mut resampled = Vec::with_capacity(new_len);

    for i in 0..new_len {
        let src_idx = i as f32 * ratio;
        let lo = src_idx.floor() as usize;
        let hi = (lo + 1).min(samples.len() - 1);
        let t = src_idx - src_idx.floor();
        resampled.push(samples[lo] * (1.0 - t) + samples[hi] * t);
    }
    resampled
}
