%%% @doc Stable Erlang wrapper for the Whisper Rust NIF.
-module(hb_whisper_nif).
-export([init/0, init_whisper/1, free_whisper/0, transcribe_audio/2, free_memory/0]).

-on_load(init/0).

-include("include/cargo.hrl").

-define(NOT_LOADED, not_loaded(?LINE)).

%% @doc Load the Rustler library.
init() ->
    ?load_nif_from_crate(hb_whisper_nif, 0).

%% @doc Load a GGML Whisper model from disk.
init_whisper(_ModelPath) ->
    ?NOT_LOADED.

%% @doc Free the loaded model.
free_whisper() ->
    ?NOT_LOADED.

%% @doc Transcribe encoded audio bytes.
transcribe_audio(_AudioData, _Language) ->
    ?NOT_LOADED.

%% @doc Release transient native memory.
free_memory() ->
    ?NOT_LOADED.

not_loaded(Line) ->
    erlang:nif_error({not_loaded, [{module, ?MODULE}, {line, Line}]}).
