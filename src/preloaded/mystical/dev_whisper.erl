%%% @doc Transcribe Arweave-hosted audio using a Rust Whisper NIF.
-module(dev_whisper).
-implements(<<"whisper@1.0">>).

-export([info/1, transcribe/3]).

-include("include/hb.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(DEFAULT_GATEWAY, <<"https://arweave.net">>).
-define(DEFAULT_MODEL, <<"/usr/local/share/whisper/models/ggml-base.bin">>).
-define(TEMP_DIR, <<"/tmp/hyperbeam-whisper">>).
info(_Opts) ->
    #{
        default => fun transcribe_key/4,
        excludes => [<<"keys">>, <<"set">>]
    }.

transcribe_key(_Name, Base, Req, Opts) ->
    transcribe(Base, Req, Opts).

transcribe(Base, Request, Opts) ->
    case find_txid(Base, Request, Opts) of
        {ok, TXID} ->
            do_transcribe(TXID, Request, Opts);
        {error, Reason} ->
            ?event(warning, {whisper_missing_txid, Reason}),
            return_error(<<"No `tx' or `raw' key found. Provide an Arweave TXID.">>, 400)
    end.

do_transcribe(TXID, Request, Opts) ->
    Gateway = request_binary(<<"gateway">>, Request, ?DEFAULT_GATEWAY, Opts),
    ModelPath = model_path(Request, Opts),
    Language = request_binary(<<"language">>, Request, <<"auto">>, Opts),
    case fetch_audio(Gateway, TXID) of
        {ok, AudioData} ->
            meter_input_bytes(AudioData, Opts),
            case ensure_model(ModelPath) of
                ok ->
                    run_nif(AudioData, Language);
                {error, Reason} ->
                    return_error(iolist_to_binary([<<"Failed to load Whisper model: ">>, Reason]), 500)
            end;
        {error, Reason} ->
            return_error(
                iolist_to_binary([
                    <<"Failed to fetch audio from Arweave: ">>,
                    io_lib:format("~p", [Reason])
                ]),
                502
            )
    end.

meter_input_bytes(AudioData, Opts) ->
    Bytes = byte_size(AudioData),
    {ok, Metering} = hb_device_load:reference(<<"metering@1.0">>, Opts),
    ok = Metering:consume(<<"media-input-bytes">>, Bytes, Opts),
    ok = Metering:consume(<<"whisper-input-bytes">>, Bytes, Opts).

ensure_model(ModelPath) ->
    case hb_whisper_nif:init_whisper(ModelPath) of
        ok -> ok;
        {error, Reason} when is_binary(Reason) -> {error, Reason};
        {error, Reason} -> {error, hb_util:bin(Reason)}
    end.

run_nif(AudioData, Language) ->
    case hb_whisper_nif:transcribe_audio(AudioData, Language) of
        {ok, JsonResult} ->
            parse_result(hb_util:bin(JsonResult));
        {error, Reason} when is_binary(Reason) ->
            return_error(iolist_to_binary([<<"Transcription failed: ">>, Reason]), 500);
        {error, Reason} ->
            return_error(
                iolist_to_binary([<<"Transcription failed: ">>, io_lib:format("~p", [Reason])]),
                500
            )
    end.

parse_result(JsonResult) ->
    try hb_json:decode(JsonResult) of
        #{<<"transcript">> := Transcript, <<"language">> := Language, <<"segments">> := Segments} ->
            success_response(hb_util:bin(Transcript), hb_util:bin(Language), Segments);
        _ ->
            return_error(<<"Whisper NIF returned an unexpected JSON shape.">>, 500)
    catch
        _:_ ->
            return_error(<<"Failed to parse Whisper NIF JSON output.">>, 500)
    end.

success_response(Transcript, Language, Segments) ->
    Payload = #{
        <<"device">> => <<"whisper@1.0">>,
        <<"language">> => Language,
        <<"segments">> => Segments,
        <<"status">> => 200,
        <<"transcript">> => Transcript
    },
    {ok, Payload#{
        <<"body">> => hb_json:encode(Payload),
        <<"content-type">> => <<"application/json">>
    }}.

find_txid(Base, Request, Opts) ->
    case first_present(
        [
            hb_maps:get(<<"tx">>, Request, undefined, Opts),
            hb_maps:get(<<"raw">>, Request, undefined, Opts),
            hb_maps:get(<<"body">>, Request, undefined, Opts),
            hb_maps:get(<<"tx">>, Base, undefined, Opts)
        ]
    ) of
        undefined ->
            {error, not_found};
        Value ->
            TXID = hb_util:bin(Value),
            case byte_size(TXID) >= 20 of
                true -> {ok, TXID};
                false -> {error, invalid_txid}
            end
    end.

first_present([]) ->
    undefined;
first_present([undefined | Rest]) ->
    first_present(Rest);
first_present([<<>> | Rest]) ->
    first_present(Rest);
first_present([Value | _Rest]) ->
    Value.

request_binary(Key, Request, Default, Opts) ->
    case hb_maps:get(Key, Request, Default, Opts) of
        undefined -> Default;
        Value -> hb_util:bin(Value)
    end.

model_path(Request, Opts) ->
    case hb_maps:get(<<"model">>, Request, undefined, Opts) of
        undefined ->
            case os:getenv("WHISPER_MODEL") of
                false -> ?DEFAULT_MODEL;
                Path -> hb_util:bin(Path)
            end;
        Path ->
            hb_util:bin(Path)
    end.

fetch_audio(Gateway, TXID) ->
    URL = iolist_to_binary([Gateway, <<"/">>, TXID]),
    ID = integer_to_binary(erlang:unique_integer([positive, monotonic])),
    TempFile = iolist_to_binary([?TEMP_DIR, <<"/fetch_">>, ID, <<".bin">>]),
    HeadersFile = iolist_to_binary([TempFile, <<".headers">>]),
    ok = filelib:ensure_dir(binary_to_list(TempFile)),
    Cmd = io_lib:format(
        "curl -fsSL --max-time 120 -o ~s -D ~s ~s 2>&1",
        [shell_quote(TempFile), shell_quote(HeadersFile), shell_quote(URL)]
    ),
    try
        case os:cmd(lists:flatten(Cmd)) of
            "" ->
                read_nonempty_file(TempFile);
            Output ->
                {error, {curl_error, hb_util:bin(Output)}}
        end
    after
        file:delete(TempFile),
        file:delete(HeadersFile)
    end.

read_nonempty_file(Path) ->
    case file:read_file(Path) of
        {ok, Body} when byte_size(Body) > 0 -> {ok, Body};
        {ok, <<>>} -> {error, empty_response};
        {error, Reason} -> {error, Reason}
    end.

shell_quote(Value) when is_binary(Value) ->
    shell_quote(binary_to_list(Value));
shell_quote(Value) when is_list(Value) ->
    lists:flatten([$', lists:flatmap(fun shell_quote_char/1, Value), $']).

shell_quote_char($') ->
    "'\\''";
shell_quote_char(Char) ->
    [Char].

return_error(Reason, Status) ->
    {error, #{
        <<"status">> => Status,
        <<"body">> => Reason,
        <<"content-type">> => <<"text/plain">>
    }}.

missing_tx_test() ->
    {error, Err} = transcribe(#{}, #{}, #{}),
    ?assertEqual(400, maps:get(<<"status">>, Err)).

parse_result_test() ->
    Json = hb_json:encode(#{
        <<"transcript">> => <<"hello world">>,
        <<"language">> => <<"en">>,
        <<"segments">> => []
    }),
    {ok, Res} = parse_result(Json),
    ?assertEqual(<<"application/json">>, maps:get(<<"content-type">>, Res)),
    ?assertEqual(<<"hello world">>, maps:get(<<"transcript">>, Res)).

shell_quote_test() ->
    ?assertEqual("'abc'\\''def'", shell_quote("abc'def")).

meter_input_bytes_test() ->
    Opts = #{
        <<"store">> => hb_test_utils:test_store(),
        <<"metering-rates">> => #{
            <<"media-input-bytes">> => 1,
            <<"whisper-input-bytes">> => 10,
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
