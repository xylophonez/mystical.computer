//! dev_whisper - Standalone Rust NIF for HyperBEAM
//!
//! Fully self-contained: audio decoding via symphonia (no CLI subprocess),
//! model inference via whisper-rs (wraps whisper.cpp). No external binaries
//! required at runtime beyond the whisper GGML model file.
//!
//! Supported input formats (via symphonia): WAV, MP3, OGG (Vorbis),
//! FLAC, AAC/M4A, and more.

pub mod logging;
pub mod transcribe;

/// init_whisper(ModelPath) -> ok | {error, Reason}
#[rustler::nif]
pub fn init_whisper<'a>(env: Env<'a>, model_path: String) -> NifResult<Term<'a>> {
    match transcribe::init_model(&model_path) {
        Ok(()) => Ok((atom::ok()).encode(env)),
        Err(e) => Ok((atom::error(), format!("{}", e)).encode(env)),
    }
}

/// free_whisper() -> ok
#[rustler::nif]
pub fn free_whisper<'a>(env: Env<'a>) -> NifResult<Term<'a>> {
    transcribe::free_model();
    Ok(atom::ok().encode(env))
}

/// transcribe_audio(AudioData, Language) -> {ok, JsonResult} | {error, Reason}
/// AudioData: encoded audio bytes (MP3, WAV, OGG, FLAC, M4A, ...)
/// Language: BCP-47 tag or "auto"
/// Returns: {ok, <<"{transcript,language,segments}">>} | {error, Reason}
#[rustler::nif(schedule = "DirtyCpu")]
pub fn transcribe_audio<'a>(
    env: Env<'a>,
    audio_data: Binary<'a>,
    language: String,
) -> NifResult<Term<'a>> {
    match transcribe::run_transcribe(audio_data.as_slice().to_vec(), &language) {
        Ok(json) => Ok((atom::ok(), json).encode(env)),
        Err(e) => Ok((atom::error(), format!("{}", e)).encode(env)),
    }
}

/// free_memory() -> ok  (stub for backwards compat)
#[rustler::nif]
pub fn free_memory<'a>(env: Env<'a>) -> NifResult<Term<'a>> {
    Ok(atom::ok().encode(env))
}

// ---------------------------------------------------------------------------
// Module registration
// ---------------------------------------------------------------------------

use rustler::types::atom;
use rustler::{Binary, Encoder, Env, NifResult, Term};

rustler::init!("hb_whisper_nif");
