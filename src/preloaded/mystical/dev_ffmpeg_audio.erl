%%% @doc Transcode audio stored on Arweave using ffmpeg.
%%%
%%% Inputs: An Arweave transaction ID pointing to an audio file, plus
%%% optional transcode parameters.
%%%   - `tx` - the Arweave TXID (binary)
%%%   - `raw` - alternative key name for the TXID
%%%   - `gateway` - optional Arweave gateway URL override
%%%   - `format` - target format: mp3|opus|aac|ogg|flac|wav|alac
%%%   - `quality` - quality preset: low|medium|high (lossy formats only)
%%%   - `samplerate` - target sample rate: 8000|16000|22050|24000|44100|48000
%%%   - `channels` - target channel count: mono|stereo
%%%   - `start` - start time in seconds (float)
%%%   - `duration` - duration in seconds (float)
%%%   - `normalize` - "true" to apply loudness normalization
%%%
%%% Outputs: A message with:
%%%   - the transcoded audio binary (body)
%%%   - metadata: format, codec, duration, samplerate, channels, bitrate, size
%%%
%%% ## ffmpeg Binary
%%%
%%% The device expects ffmpeg on the host PATH or at the configured
%%% path via the node option `ffmpeg_binary`
%%% (default: `/usr/bin/ffmpeg`).
%%%
%%% ## Usage
%%%
%%% ```
%%% GET /~ffmpeg-audio@1.0/transcode?tx=<arweave_txid>&format=mp3
%%% GET /~ffmpeg-audio@1.0/transcode?tx=<txid>&format=opus&quality=high
%%% GET /~ffmpeg-audio@1.0/transcode?tx=<txid>&format=mp3&channels=mono&samplerate=16000
%%% GET /~ffmpeg-audio@1.0/transcode?tx=<txid>&format=mp3&start=0&duration=300&normalize=true
%%% GET /~ffmpeg-audio@1.0/transcode?tx=<txid>&format=flac
%%% ```

-module(dev_ffmpeg_audio).
-implements(<<"ffmpeg-audio@1.0">>).
-export([info/1, transcode/3]).
-include("include/hb.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(TEMP_DIR, <<"/tmp/hyperbeam-ffmpeg">>).
-define(DEFAULT_GATEWAY, <<"https://arweave.net">>).
-define(DEFAULT_BINARY, <<"/usr/bin/ffmpeg">>).
-define(DEFAULT_CURL_BINARY, <<"/usr/bin/curl">>).
-define(DEFAULT_FETCH_TIMEOUT_MS, 120000).
-define(DEFAULT_FFMPEG_TIMEOUT_MS, 300000).
-define(DEFAULT_FFPROBE_TIMEOUT_MS, 30000).

%% Supported output formats with their ffmpeg codec names and content-types.
-define(FORMATS, #{
    <<"mp3">>  => #{codec => <<"libmp3lame">>, ext => <<".mp3">>,  ct => <<"audio/mpeg">>},
    <<"opus">> => #{codec => <<"libopus">>,    ext => <<".opus">>, ct => <<"audio/opus">>},
    <<"aac">>  => #{codec => <<"aac">>,        ext => <<".m4a">>,  ct => <<"audio/mp4">>},
    <<"ogg">>  => #{codec => <<"libvorbis">>,  ext => <<".ogg">>,  ct => <<"audio/ogg">>},
    <<"flac">> => #{codec => <<"flac">>,       ext => <<".flac">>, ct => <<"audio/flac">>},
    <<"wav">>  => #{codec => <<"pcm_s16le">>,  ext => <<".wav">>,  ct => <<"audio/wav">>},
    <<"alac">> => #{codec => <<"alac">>,       ext => <<".m4a">>,  ct => <<"audio/mp4">>}
}).

%% Quality presets: {bitrate_string} per format.
-define(QUALITY_PRESETS, #{
    <<"low">>    => #{<<"mp3">>  => "96k",
                      <<"opus">> => "48k",
                      <<"aac">>  => "64k",
                      <<"ogg">>  => "64k"},
    <<"medium">> => #{<<"mp3">>  => "192k",
                      <<"opus">> => "96k",
                      <<"aac">>  => "128k",
                      <<"ogg">>  => "128k"},
    <<"high">>   => #{<<"mp3">>  => "320k",
                      <<"opus">> => "128k",
                      <<"aac">>  => "256k",
                      <<"ogg">>  => "256k"}
}).

%% @doc Register the device's default handler.
info(_Opts) ->
    #{
        default => fun transcribe_key/4,
        excludes => [<<"keys">>, <<"set">>]
    }.

%% @doc Default handler - dispatch to transcode for any key access.
transcribe_key(_Name, Base, Req, Opts) ->
    transcode(Base, Req, Opts).

%% @doc Transcode an audio file fetched from Arweave using ffmpeg.
transcode(Base, Request, Opts) ->
    ?event(debug_ffmpeg_audio, {transcode_request, {base, Base}, {request, Request}}),

    %% Extract the Arweave TXID
    case find_txid(Base, Request, Opts) of
        {ok, Id} when is_binary(Id), byte_size(Id) >= 20 ->
            do_transcode(Id, Base, Request, Opts);
        {ok, Id} ->
            Normalized = hb_util:bin(Id),
            case byte_size(Normalized) >= 20 of
                true ->
                    do_transcode(Normalized, Base, Request, Opts);
                false ->
                    ?event(warning, {invalid_txid, Id}),
                    return_error(<<"Invalid Arweave transaction ID.">>, 400)
            end;
        Error ->
            ?event(error, {missing_txid, Error}),
            return_error(<<"No `tx' or `raw' key found. Provide an Arweave TXID.">>,
                         400)
    end.

%% @doc Main transcode workflow after TXID extraction.
do_transcode(TXID, _Base, Request, Opts) ->
    %% Determine gateway URL
    Gateway = hb_maps:get(<<"gateway">>, Request,
                hb_maps:get(<<"gateway">>, #{},
                    ?DEFAULT_GATEWAY, Opts), Opts),

    %% Parse transcode options
    case parse_options(Request, Opts) of
        {ok, TranscodeOpts} ->
            ?event(debug_ffmpeg_audio, {options, TranscodeOpts}),
            %% Fetch the audio data from Arweave
            ?event(debug_ffmpeg_audio, {fetching_audio, {txid, TXID}, {gateway, Gateway}}),
            case fetch_audio(Gateway, TXID, Opts) of
                {ok, AudioData, ContentType} ->
                    ?event(debug_ffmpeg_audio, {audio_fetched,
                        {size, byte_size(AudioData)},
                        {content_type, ContentType}}),
                    meter_input_bytes(AudioData, Opts),
                    run_ffmpeg(AudioData, ContentType, TranscodeOpts, Request, Opts);
                {error, Reason} ->
                    ?event(error, {fetch_failed, {txid, TXID}, {reason, Reason}}),
                    return_error(iolist_to_binary(["Failed to fetch audio from Arweave: ",
                                           io_lib:format("~p", [Reason])]), 502)
            end;
        {error, Reason, Status} ->
            return_error(Reason, Status)
    end.

%% @doc Parse and validate transcode options from request.
parse_options(Request, Opts) ->
    %% Target format
    case parse_format_param(Request, Opts) of
        {ok, Format} ->
            %% Quality preset
            case parse_quality_param(Request, Opts) of
                {ok, Quality} ->
                    %% Sample rate
                    case parse_samplerate_param(Request, Opts) of
                        {ok, SampleRate} ->
                            %% Channels
                            case parse_channels_param(Request, Opts) of
                                {ok, Channels} ->
                                    case parse_start_param(Request, Opts) of
                                        {ok, Start} ->
                                            case parse_duration_param(Request, Opts) of
                                                {ok, Duration} ->
                                                    Normalize = parse_normalize_param(Request, Opts),
                                                    {ok, #{
                                                        format => Format,
                                                        quality => Quality,
                                                        samplerate => SampleRate,
                                                        channels => Channels,
                                                        start => Start,
                                                        duration => Duration,
                                                        normalize => Normalize
                                                    }};
                                                {error, R, S} -> {error, R, S}
                                            end;
                                        {error, R, S} -> {error, R, S}
                                    end;
                                {error, R, S} -> {error, R, S}
                            end;
                        {error, R, S} -> {error, R, S}
                    end;
                {error, R, S} -> {error, R, S}
            end;
        {error, R, S} -> {error, R, S}
    end.

parse_format_param(Request, Opts) ->
    case hb_maps:get(<<"format">>, Request, undefined, Opts) of
        undefined -> {ok, <<"mp3">>};
        F when is_binary(F) -> parse_format(F);
        F when is_list(F) -> parse_format(iolist_to_binary(F))
    end.

parse_format(F) ->
    case ?FORMATS of
        #{F := _} -> {ok, F};
        _ ->
            Supported = lists:join(", ",
                [binary_to_list(K) || K <- maps:keys(?FORMATS)]),
            {error, iolist_to_binary([
                "Unsupported format: ", binary_to_list(F),
                ". Supported: ", Supported]), 400}
    end.

parse_quality_param(Request, Opts) ->
    case hb_maps:get(<<"quality">>, Request, undefined, Opts) of
        undefined -> {ok, <<"medium">>};
        Q when is_binary(Q) -> parse_quality(Q);
        Q when is_list(Q) -> parse_quality(iolist_to_binary(Q))
    end.

parse_quality(Q) ->
    case lists:member(Q, [<<"low">>, <<"medium">>, <<"high">>]) of
        true -> {ok, Q};
        false -> {error, <<"Quality must be low, medium, or high.">>, 400}
    end.

parse_samplerate_param(Request, Opts) ->
    case hb_maps:get(<<"samplerate">>, Request, undefined, Opts) of
        undefined -> {ok, undefined};
        SR when is_binary(SR) ->
            case valid_samplerate(SR) of
                true -> {ok, SR};
                false -> {error, <<"Sample rate must be one of: 8000, 16000, 22050, 24000, 44100, 48000.">>, 400}
            end;
        SR when is_list(SR) ->
            B = iolist_to_binary(SR),
            case valid_samplerate(B) of
                true -> {ok, B};
                false -> {error, <<"Sample rate must be one of: 8000, 16000, 22050, 24000, 44100, 48000.">>, 400}
            end
    end.

parse_channels_param(Request, Opts) ->
    case hb_maps:get(<<"channels">>, Request, undefined, Opts) of
        undefined -> {ok, undefined};
        C when is_binary(C) -> parse_channels(C);
        C when is_list(C) -> parse_channels(iolist_to_binary(C))
    end.

parse_channels(C) ->
    case lists:member(C, [<<"mono">>, <<"stereo">>]) of
        true -> {ok, C};
        false -> {error, <<"Channels must be mono or stereo.">>, 400}
    end.

parse_start_param(Request, Opts) ->
    parse_number_param(
        <<"start">>,
        <<"Start must be a non-negative number of seconds.">>,
        Request,
        Opts
    ).

parse_duration_param(Request, Opts) ->
    parse_number_param(
        <<"duration">>,
        <<"Duration must be a non-negative number of seconds.">>,
        Request,
        Opts
    ).

parse_number_param(Key, Error, Request, Opts) ->
    case hb_maps:get(Key, Request, undefined, Opts) of
        undefined -> {ok, undefined};
        N when is_integer(N), N >= 0 -> {ok, N};
        N when is_float(N), N >= 0 -> {ok, N};
        B when is_binary(B) -> parse_number(B, Error);
        L when is_list(L) -> parse_number(iolist_to_binary(L), Error);
        _ -> {error, Error, 400}
    end.

parse_number(Bin, Error) ->
    case parse_float(Bin, invalid) of
        invalid -> {error, Error, 400};
        Number -> {ok, Number}
    end.

parse_normalize_param(Request, Opts) ->
    case hb_maps:get(<<"normalize">>, Request, undefined, Opts) of
        undefined -> false;
        <<"true">> -> true;
        <<"1">> -> true;
        true -> true;
        _ -> false
    end.

%% @doc Check if a sample rate is valid.
valid_samplerate(SR) ->
    lists:member(SR, [<<"8000">>, <<"16000">>, <<"22050">>, <<"24000">>, <<"44100">>, <<"48000">>]).

%% @doc Parse a float from a binary, returning Default on failure.
parse_float(Bin, Default) ->
    Str = binary_to_list(Bin),
    try list_to_float(Str) of
        F when F >= 0 -> F;
        _ -> Default
    catch
        _:_ ->
            try list_to_integer(Str) of
                I when I >= 0 -> I;
                _ -> Default
            catch
                _:_ -> Default
            end
    end.

%% @doc Fetch audio data from an Arweave gateway using curl.
fetch_audio(Gateway, TXID, Opts) ->
    URL = iolist_to_binary([Gateway, "/", TXID]),
    ?event(debug_ffmpeg_audio, {http_get, {url, URL}}),

    TempFile = iolist_to_binary(io_lib:format("/tmp/hyperbeam-ffmpeg/fetch_~p.bin",
                                              [erlang:unique_integer([positive])])),
    HeadersFile = iolist_to_binary([TempFile, ".headers"]),
    ok = filelib:ensure_dir(TempFile),

    CurlBin = ensure_binary_path(hb_opts:get(curl_binary, ?DEFAULT_CURL_BINARY, Opts)),
    FetchTimeoutMs = timeout_ms(curl_timeout, ?DEFAULT_FETCH_TIMEOUT_MS, Opts),
    CurlArgs = [
        "-fsSL",
        "--max-time", integer_to_list(max(1, FetchTimeoutMs div 1000)),
        "-o", binary_to_list(TempFile),
        "-D", binary_to_list(HeadersFile),
        binary_to_list(URL)
    ],
    ?event(debug_ffmpeg_audio, {curl_cmd, {bin, CurlBin}, {args, CurlArgs}}),

    try
        case run_executable(CurlBin, CurlArgs, FetchTimeoutMs + 5000) of
            {ok, _Output} ->
                case file:read_file(TempFile) of
                    {ok, Body} when byte_size(Body) > 0 ->
                        ContentType = parse_content_type(TempFile),
                        ?event(debug_ffmpeg_audio, {fetched, {size, byte_size(Body)},
                            {content_type, ContentType}}),
                        {ok, Body, ContentType};
                    {ok, <<>>} ->
                        {error, empty_response};
                    {error, ReadErr} ->
                        {error, ReadErr}
                end;
            {error, Error} ->
                {error, {curl_error, format_command_error(Error)}}
        end
    after
        file:delete(TempFile),
        file:delete(HeadersFile)
    end.

%% @doc Parse content-type from curl headers file.
parse_content_type(TempFile) ->
    HeadersFile = iolist_to_binary([TempFile, ".headers"]),
    case file:read_file(HeadersFile) of
        {ok, RawHeaders} ->
            Lines = binary:split(RawHeaders, <<"\n">>, [global]),
            lists:foldl(fun(Line, Acc) ->
                case content_type_header(Line) of
                    undefined -> Acc;
                    ContentType -> ContentType
                end
            end, undefined, Lines);
        _ -> undefined
    end.

content_type_header(Line) ->
    case binary:split(Line, <<":">>) of
        [Name, Value0] ->
            LowerName = list_to_binary(string:to_lower(binary_to_list(
                string:trim(Name, both, " \t\r\n")
            ))),
            case LowerName of
                <<"content-type">> ->
                    string:trim(Value0, both, " \t\r\n");
                _ -> undefined
            end;
        _ -> undefined
    end.

%% @doc Run ffmpeg to transcode audio data.
run_ffmpeg(AudioData, ContentType, TranscodeOpts, _Request, Opts) ->
    %% Ensure temp directory exists
    ok = filelib:ensure_dir(iolist_to_binary([?TEMP_DIR, "/input.bin"])),

    %% Get ffmpeg binary path
    FfmpegBin0 = hb_opts:get(ffmpeg_binary, ?DEFAULT_BINARY, Opts),
    FfmpegBin = ensure_binary_path(FfmpegBin0),

    case filelib:is_regular(FfmpegBin) of
        true ->
            %% Determine input extension from content-type
            InExt = guess_input_ext(ContentType),
            Unique = erlang:unique_integer([positive]),
            InFile = iolist_to_binary(io_lib:format(
                "/tmp/hyperbeam-ffmpeg/input_~p~s", [Unique, InExt]
            )),

            %% Determine output format info
            Format = maps:get(format, TranscodeOpts),
            FormatInfo = maps:get(Format, ?FORMATS),
            OutExt = maps:get(ext, FormatInfo),
            OutFile = iolist_to_binary(io_lib:format(
                "/tmp/hyperbeam-ffmpeg/output_~p~s", [Unique, OutExt]
            )),

            %% Write input audio
            ?event(debug_ffmpeg_audio, {writing_input, {file, InFile},
                {size, byte_size(AudioData)}}),
            case file:write_file(InFile, AudioData) of
                ok ->
                    build_and_run_ffmpeg(FfmpegBin, InFile, OutFile,
                                         TranscodeOpts, FormatInfo, Opts);
                {error, WriteErr} ->
                    ?event(error, {write_input_failed, WriteErr}),
                    return_error(<<"Failed to write temporary audio file.">>, 500)
            end;
        false ->
            return_error(iolist_to_binary(["ffmpeg binary not found at: ",
                                           binary_to_list(FfmpegBin)]), 500)
    end.

%% @doc Build and execute the ffmpeg command.
build_and_run_ffmpeg(FfmpegBin, InFile, OutFile, TranscodeOpts, FormatInfo, Opts) ->
    try
        %% Build ffmpeg command arguments
        Codec = maps:get(codec, FormatInfo),
        Format = maps:get(format, TranscodeOpts),
        Quality = maps:get(quality, TranscodeOpts),

        FfmpegArgs = build_ffmpeg_args(InFile, OutFile,
                                       Codec, Format, Quality, TranscodeOpts),
        ?event(debug_ffmpeg_audio, {running_ffmpeg, {bin, FfmpegBin}, {args, FfmpegArgs}}),

        FfmpegTimeoutMs = timeout_ms(ffmpeg_timeout, ?DEFAULT_FFMPEG_TIMEOUT_MS, Opts),
        FfmpegResult = run_executable(FfmpegBin, FfmpegArgs, FfmpegTimeoutMs),
        FfmpegOutput = command_output(FfmpegResult),
        ?event(debug_ffmpeg_audio, {ffmpeg_done, {output_len, byte_size(FfmpegOutput)}}),

        case FfmpegResult of
            {ok, _} ->
                %% Check output file exists and is non-empty
                case file:read_file(OutFile) of
                    {ok, OutputData} when byte_size(OutputData) > 0 ->
                        Metadata = probe_metadata(OutFile, FfmpegBin, Opts),
                        ?event(debug_ffmpeg_audio, {transcode_success,
                            {size, byte_size(OutputData)},
                            {metadata, Metadata}}),
                        success_response(OutputData, FormatInfo, Metadata, TranscodeOpts);
                    {ok, <<>>} ->
                        return_error(iolist_to_binary([
                            "ffmpeg produced empty output. output: ", FfmpegOutput
                        ]), 500);
                    {error, ReadErr} ->
                        return_error(iolist_to_binary([
                            "ffmpeg failed to produce output: ",
                            io_lib:format("~p", [ReadErr]),
                            ". output: ", FfmpegOutput
                        ]), 500)
                end;
            {error, Error} ->
                return_error(iolist_to_binary([
                    "ffmpeg failed: ", format_command_error(Error)
                ]), 500)
        end
    catch ErrorType:Reason ->
        ?event(error, {transcode_crash, {type, ErrorType}, {reason, Reason}}),
        return_error(iolist_to_binary(["Transcode crashed: ",
                       io_lib:format("~p", [Reason])]),
                     500)
    after
        %% Always clean up temp files
        file:delete(InFile),
        file:delete(OutFile)
    end.

%% @doc Build the ffmpeg argument list.
build_ffmpeg_args(InFile, OutFile, Codec, Format, Quality, Opts) ->
    Parts0 = [
        "-hide_banner",
        "-nostdin",
        "-y",                          %% overwrite output
        "-i", binary_to_list(InFile)   %% input file
    ],

    %% Audio-only filter (strip video if present)
    Parts1 = Parts0 ++ ["-vn"],

    %% Sample rate
    Parts2 = case maps:get(samplerate, Opts, undefined) of
        undefined -> Parts1;
        SR -> Parts1 ++ ["-ar", binary_to_list(SR)]
    end,

    %% Channels
    Parts3 = case maps:get(channels, Opts, undefined) of
        undefined -> Parts2;
        <<"mono">> -> Parts2 ++ ["-ac", "1"];
        <<"stereo">> -> Parts2 ++ ["-ac", "2"]
    end,

    %% Start / duration (input-side for efficiency)
    Parts4 = case maps:get(start, Opts, undefined) of
        undefined -> Parts3;
        S when is_number(S) ->
            Parts3 ++ ["-ss", number_arg(S)]
    end,
    Parts5 = case maps:get(duration, Opts, undefined) of
        undefined -> Parts4;
        D when is_number(D) ->
            Parts4 ++ ["-t", number_arg(D)]
    end,

    %% Audio filter chain
    FilterParts = case maps:get(normalize, Opts, false) of
        true -> ["loudnorm=print_format=json"];
        false -> []
    end,
    Parts6 = case FilterParts of
        [] -> Parts5;
        _ -> Parts5 ++ ["-af", string:join(FilterParts, ",")]
    end,

    %% Codec
    Parts7 = Parts6 ++ ["-acodec", binary_to_list(Codec)],

    %% Quality (bitrate) for lossy formats
    Parts8 = case get_quality_bitrate(Format, Quality) of
        undefined -> Parts7;  %% lossless or no preset
        Bitrate -> Parts7 ++ ["-b:a", Bitrate]
    end,

    %% Output
    Parts8 ++ [binary_to_list(OutFile)].

number_arg(N) when is_integer(N) ->
    integer_to_list(N);
number_arg(N) when is_float(N) ->
    lists:flatten(io_lib:format("~.3f", [N])).

%% @doc Probe output file metadata using ffprobe.
probe_metadata(OutFile, FfmpegBin, Opts) ->
    FfprobeCandidate = ensure_binary_path(
        hb_opts:get(ffprobe_binary, derive_ffprobe_path(FfmpegBin), Opts)
    ),
    Ffprobe = case filelib:is_regular(FfprobeCandidate) of
        true -> FfprobeCandidate;
        false -> <<"/usr/bin/ffprobe">>
    end,

    Args = [
        "-v", "quiet",
        "-print_format", "json",
        "-show_format",
        "-show_streams",
        binary_to_list(OutFile)
    ],
    case run_executable(Ffprobe, Args, timeout_ms(ffprobe_timeout, ?DEFAULT_FFPROBE_TIMEOUT_MS, Opts)) of
        {ok, <<>>} -> #{};
        {ok, ProbeOut} ->
            try
                ProbeJson = hb_json:decode(ProbeOut),
                extract_probe_metadata(ProbeJson)
            catch
                _:_ -> #{}
            end;
        {error, _} -> #{}
    end.

derive_ffprobe_path(FfmpegBin) ->
    Filename = binary_to_list(FfmpegBin),
    case filename:basename(Filename) of
        "ffmpeg" ->
            iolist_to_binary(filename:join(filename:dirname(Filename), "ffprobe"));
        _ ->
            binary:replace(FfmpegBin, <<"ffmpeg">>, <<"ffprobe">>, [global])
    end.

%% @doc Extract relevant metadata from ffprobe JSON.
extract_probe_metadata(ProbeJson) when is_map(ProbeJson) ->
    %% Get format-level metadata
    FormatMap = maps:get(<<"format">>, ProbeJson, #{}),
    Duration = case maps:get(<<"duration">>, FormatMap, undefined) of
        undefined -> undefined;
        D when is_binary(D) -> parse_float(D, undefined);
        D when is_number(D) -> D
    end,
    BitRate = case maps:get(<<"bit_rate">>, FormatMap, undefined) of
        undefined -> undefined;
        B when is_binary(B) -> parse_float(B, undefined);
        B when is_number(B) -> B
    end,

    Streams = maps:get(<<"streams">>, ProbeJson, []),
    AudioStream = find_audio_stream(Streams),

    SampleRate = case maps:get(<<"sample_rate">>, AudioStream, undefined) of
        undefined -> undefined;
        SR when is_binary(SR) -> parse_float(SR, undefined);
        SR when is_number(SR) -> SR
    end,

    Channels = case maps:get(<<"channels">>, AudioStream, undefined) of
        undefined -> undefined;
        C when is_number(C) -> C;
        C when is_binary(C) -> parse_float(C, undefined)
    end,

    CodecName = maps:get(<<"codec_name">>, AudioStream, undefined),

    #{
        <<"duration">> => Duration,
        <<"bitrate">> => BitRate,
        <<"samplerate">> => SampleRate,
        <<"channels">> => Channels,
        <<"codec">> => CodecName
    };
extract_probe_metadata(_) -> #{}.

find_audio_stream(Streams) when is_list(Streams) ->
    case [S || S <- Streams,
               is_map(S),
               maps:get(<<"codec_type">>, S, undefined) =:= <<"audio">>] of
        [Audio | _] -> Audio;
        [] ->
            case [S || S <- Streams, is_map(S)] of
                [First | _] -> First;
                [] -> #{}
            end
    end;
find_audio_stream(_) -> #{}.

%% @doc Guess input file extension from content-type.
guess_input_ext(ContentType) ->
    case ContentType of
        undefined -> <<".wav">>;
        CT when is_binary(CT) ->
            Lc = list_to_binary(string:to_lower(binary_to_list(CT))),
            guess_ext_from_ct(Lc);
        _ -> <<".wav">>
    end.

guess_ext_from_ct(CT) ->
    case binary:match(CT, <<"mp3">>) of
        {_, _} -> <<".mp3">>;
        nomatch ->
            case binary:match(CT, <<"mpeg">>) of
                {_, _} -> <<".mp3">>;
                nomatch ->
                    case binary:match(CT, <<"ogg">>) of
                        {_, _} -> <<".ogg">>;
                        nomatch ->
                            case binary:match(CT, <<"flac">>) of
                                {_, _} -> <<".flac">>;
                                nomatch ->
                                    case binary:match(CT, <<"wav">>) of
                                        {_, _} -> <<".wav">>;
                                        nomatch ->
                                            case binary:match(CT, <<"m4a">>) of
                                                {_, _} -> <<".m4a">>;
                                                nomatch ->
                                                    case binary:match(CT, <<"opus">>) of
                                                        {_, _} -> <<".opus">>;
                                                        nomatch ->
                                                            case binary:match(CT, <<"aac">>) of
                                                                {_, _} -> <<".m4a">>;
                                                                nomatch ->
                                                                    case binary:match(CT, <<"webm">>) of
                                                                        {_, _} -> <<".webm">>;
                                                                        nomatch ->
                                                                            case binary:match(CT, <<"mp4">>) of
                                                                                {_, _} -> <<".mp4">>;
                                                                                nomatch -> <<".wav">>
                                                                            end
                                                                    end
                                                            end
                                                    end
                                            end
                                    end
                            end
                    end
            end
    end.

%% @doc Build a success response with transcoded audio and metadata.
success_response(AudioData, FormatInfo, Metadata, TranscodeOpts) ->
    ContentType = maps:get(ct, FormatInfo),
    Format = maps:get(format, TranscodeOpts),

    %% Build metadata payload
    MetaPayload = maps:merge(#{
        <<"device">> => <<"ffmpeg-audio@1.0">>,
        <<"format">> => Format,
        <<"size">> => byte_size(AudioData),
        <<"status">> => 200
    }, Metadata),

    {ok, MetaPayload#{
        <<"body">> => AudioData,
        <<"content-type">> => ContentType
    }}.

%% @doc Return an error message.
return_error(Reason, Status) ->
    {error, #{
        <<"status">> => Status,
        <<"body">> => Reason,
        <<"content-type">> => <<"text/plain">>
    }}.

%% @doc Ensure a path is a binary (works with lists or binaries from OTP 27).
ensure_binary_path(Path) when is_binary(Path) -> Path;
ensure_binary_path(Path) when is_list(Path) -> iolist_to_binary(Path).

timeout_ms(Key, Default, Opts) ->
    case hb_opts:get(Key, Default, Opts) of
        N when is_integer(N), N > 0 -> N;
        N when is_float(N), N > 0 -> trunc(N);
        B when is_binary(B) ->
            case parse_float(B, invalid) of
                I when is_integer(I), I > 0 -> I;
                F when is_float(F), F > 0 -> trunc(F);
                _ -> Default
            end;
        _ -> Default
    end.

run_executable(Executable0, Args0, TimeoutMs) ->
    Executable = ensure_binary_path(Executable0),
    case filelib:is_regular(Executable) of
        false ->
            {error, {not_found, Executable}};
        true ->
            Args = [arg_to_list(Arg) || Arg <- Args0],
            try open_port(
                {spawn_executable, binary_to_list(Executable)},
                [binary, exit_status, stderr_to_stdout, use_stdio, stream, {args, Args}]
            ) of
                Port ->
                    collect_port(Port, TimeoutMs, [])
            catch
                error:Reason ->
                    {error, {spawn_failed, Reason}}
            end
    end.

arg_to_list(Arg) when is_binary(Arg) -> binary_to_list(Arg);
arg_to_list(Arg) when is_integer(Arg) -> integer_to_list(Arg);
arg_to_list(Arg) when is_float(Arg) -> number_arg(Arg);
arg_to_list(Arg) when is_list(Arg) -> lists:flatten(Arg).

collect_port(Port, TimeoutMs, Acc) ->
    receive
        {Port, {data, Data}} ->
            collect_port(Port, TimeoutMs, [Data | Acc]);
        {Port, {exit_status, 0}} ->
            {ok, iolist_to_binary(lists:reverse(Acc))};
        {Port, {exit_status, Status}} ->
            {error, {exit_status, Status, iolist_to_binary(lists:reverse(Acc))}}
    after TimeoutMs ->
        catch port_close(Port),
        {error, {timeout, iolist_to_binary(lists:reverse(Acc))}}
    end.

command_output({ok, Output}) -> Output;
command_output({error, {exit_status, _Status, Output}}) -> Output;
command_output({error, {timeout, Output}}) -> Output;
command_output({error, _}) -> <<>>.

format_command_error({exit_status, Status, Output}) ->
    iolist_to_binary([
        "exit_status=", integer_to_list(Status),
        " output=", truncate_output(Output)
    ]);
format_command_error({timeout, Output}) ->
    iolist_to_binary(["timeout output=", truncate_output(Output)]);
format_command_error({not_found, Executable}) ->
    iolist_to_binary(["executable not found: ", Executable]);
format_command_error({spawn_failed, Reason}) ->
    iolist_to_binary(["spawn failed: ", io_lib:format("~p", [Reason])]);
format_command_error(Reason) ->
    iolist_to_binary(io_lib:format("~p", [Reason])).

truncate_output(Output) when byte_size(Output) > 4096 ->
    <<(binary:part(Output, 0, 4096))/binary, "...">>;
truncate_output(Output) ->
    Output.

%% @doc Find the Arweave TXID from the request or base message.
find_txid(Base, Request, Opts) ->
    find_txid_in([
        fun() -> hb_maps:get(<<"tx">>, Request, undefined, Opts) end,
        fun() -> hb_maps:get(<<"raw">>, Request, undefined, Opts) end,
        fun() ->
            case hb_maps:get(<<"body">>, Request, undefined, Opts) of
                Body when is_binary(Body), byte_size(Body) >= 20 -> Body;
                _ -> undefined
            end
        end,
        fun() -> hb_maps:get(<<"tx">>, Base, undefined, Opts) end
    ]).

%% @doc Try each source function until one returns a valid TXID.
find_txid_in([]) ->
    {error, not_found};
find_txid_in([Fun | Rest]) ->
    case Fun() of
        undefined -> find_txid_in(Rest);
        Val when is_binary(Val), byte_size(Val) > 0 ->
            {ok, Val};
        Val when is_list(Val) ->
            {ok, list_to_binary(Val)};
        Other ->
            {ok, hb_util:bin(Other)}
    end.

%% @doc Meter media input size under the shared and FFmpeg-specific counters.
meter_input_bytes(AudioData, Opts) ->
    Bytes = byte_size(AudioData),
    {ok, Metering} = hb_device_load:reference(<<"metering@1.0">>, Opts),
    ok = Metering:consume(<<"media-input-bytes">>, Bytes, Opts),
    ok = Metering:consume(<<"ffmpeg-input-bytes">>, Bytes, Opts).

%% @doc Look up bitrate for a format+quality combination.
get_quality_bitrate(Format, Quality) ->
    case maps:get(Quality, ?QUALITY_PRESETS, undefined) of
        undefined -> undefined;
        Presets when is_map(Presets) ->
            maps:get(Format, Presets, undefined)
    end.

%%% Tests

transcode_missing_tx_test() ->
    {error, Err} = transcode(#{}, #{}, #{}),
    ?assert(maps:is_key(<<"status">>, Err)),
    ?assertEqual(400, maps:get(<<"status">>, Err)).

transcode_invalid_format_test() ->
    {error, Err} = transcode(#{}, #{<<"tx">> => valid_test_txid(), <<"format">> => <<"wma">>}, #{}),
    ?assertEqual(400, maps:get(<<"status">>, Err)),
    ?assertMatch(<<"Unsupported format", _/binary>>, maps:get(<<"body">>, Err)).

parse_options_invalid_start_test() ->
    ?assertMatch(
        {error, _, 400},
        parse_options(#{<<"start">> => <<"abc">>}, #{})
    ).

guess_input_ext_mp3_test() ->
    ?assertEqual(<<".mp3">>, guess_input_ext(<<"audio/mpeg">>)).

guess_input_ext_ogg_test() ->
    ?assertEqual(<<".ogg">>, guess_input_ext(<<"audio/ogg">>)).

guess_input_ext_default_test() ->
    ?assertEqual(<<".wav">>, guess_input_ext(undefined)).

parse_float_test() ->
    ?assertEqual(3.14, parse_float(<<"3.14">>, undefined)).

parse_integer_test() ->
    ?assertEqual(3, parse_float(<<"3">>, undefined)).

parse_float_invalid_test() ->
    ?assertEqual(undefined, parse_float(<<"abc">>, undefined)).

valid_samplerate_test() ->
    ?assert(valid_samplerate(<<"44100">>)),
    ?assert(not valid_samplerate(<<"48001">>)).

quality_bitrate_test() ->
    ?assertEqual("192k", get_quality_bitrate(<<"mp3">>, <<"medium">>)),
    ?assertEqual(undefined, get_quality_bitrate(<<"flac">>, <<"medium">>)).

meter_input_bytes_test() ->
    Opts = #{
        <<"store">> => hb_test_utils:test_store(),
        <<"metering-rates">> => #{
            <<"media-input-bytes">> => 1,
            <<"ffmpeg-input-bytes">> => 10,
            <<"beam-reductions">> => 0
        }
    },
    Metering = #{ <<"device">> => <<"metering@1.0">> },
    {ok, 0} = hb_ao:resolve(Metering, #{ <<"path">> => <<"estimate">> }, Opts),
    ok = meter_input_bytes(<<"12345">>, Opts),
    ?assertEqual(
        {ok, 55},
        hb_ao:resolve(Metering, #{ <<"path">> => <<"price">> }, Opts)
    ).

derive_ffprobe_path_test() ->
    ?assertEqual(<<"/usr/bin/ffprobe">>, derive_ffprobe_path(<<"/usr/bin/ffmpeg">>)).

content_type_header_test() ->
    ?assertEqual(
        <<"audio/mpeg">>,
        content_type_header(<<"Content-Type: audio/mpeg\r">>)
    ).

build_ffmpeg_args_no_shell_test() ->
    Args = build_ffmpeg_args(
        <<"/tmp/input file's.wav">>,
        <<"/tmp/output file.mp3">>,
        <<"libmp3lame">>,
        <<"mp3">>,
        <<"low">>,
        #{channels => <<"mono">>, duration => 1}
    ),
    ?assert(lists:member("/tmp/input file's.wav", Args)),
    ?assert(lists:member("/tmp/output file.mp3", Args)),
    ?assertNot(lists:member("'/tmp/input file'\\''s.wav'", Args)).

run_executable_success_test() ->
    case filelib:is_regular(<<"/bin/echo">>) of
        false ->
            ok;
        true ->
            ?assertEqual({ok, <<"ok\n">>}, run_executable(<<"/bin/echo">>, ["ok"], 5000))
    end.

success_response_test() ->
    {ok, Res} = success_response(
        <<"audio">>,
        maps:get(<<"mp3">>, ?FORMATS),
        #{<<"duration">> => 1.0, <<"codec">> => <<"mp3">>},
        #{format => <<"mp3">>}
    ),
    ?assertEqual(<<"audio">>, maps:get(<<"body">>, Res)),
    ?assertEqual(<<"audio/mpeg">>, maps:get(<<"content-type">>, Res)),
    ?assertEqual(<<"mp3">>, maps:get(<<"format">>, Res)),
    ?assertEqual(1.0, maps:get(<<"duration">>, Res)).

run_ffmpeg_smoke_test() ->
    case filelib:is_regular(?DEFAULT_BINARY) of
        false ->
            ok;
        true ->
            {ok, Options} = parse_options(#{
                <<"format">> => <<"mp3">>,
                <<"quality">> => <<"low">>,
                <<"samplerate">> => <<"8000">>,
                <<"channels">> => <<"mono">>
            }, #{}),
            {ok, Res} = run_ffmpeg(wav_silence(), <<"audio/wav">>, Options, #{}, #{}),
            Body = maps:get(<<"body">>, Res),
            ?assert(byte_size(Body) > 0),
            ?assertEqual(<<"audio/mpeg">>, maps:get(<<"content-type">>, Res)),
            ?assertEqual(<<"ffmpeg-audio@1.0">>, maps:get(<<"device">>, Res))
    end.

valid_test_txid() ->
    <<"cqsiwN004PcOxWLnecvYL1x3o_v2CjnWtdqBCmUWaQU">>.

wav_silence() ->
    Samples = 800,
    DataSize = Samples * 2,
    ChunkSize = 36 + DataSize,
    Data = binary:copy(<<0>>, DataSize),
    Header = <<
        "RIFF",
        ChunkSize:32/little-unsigned-integer,
        "WAVE",
        "fmt ",
        16:32/little-unsigned-integer,
        1:16/little-unsigned-integer,
        1:16/little-unsigned-integer,
        8000:32/little-unsigned-integer,
        16000:32/little-unsigned-integer,
        2:16/little-unsigned-integer,
        16:16/little-unsigned-integer,
        "data",
        DataSize:32/little-unsigned-integer
    >>,
    <<Header/binary, Data/binary>>.
