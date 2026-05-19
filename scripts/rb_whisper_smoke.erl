-module(rb_whisper_smoke).
-export([main/0]).

main() ->
    ensure_apps(),
    WalletFile = getenv("WALLET_FILE"),
    Wallet = ar_wallet:load_keyfile(WalletFile),
    Address = hb_util:human_id(ar_wallet:to_address(Wallet)),
    Node = getenv_bin("HB_NODE", <<"https://rb.mystical.computer">>),
    TXID = getenv_bin("TX_ID", <<"9OaHLWDaAjSSBeGhYOyBm2BRG-SG5ppEt2rWi_z2AIs">>),
    Gateway = getenv_bin("WHISPER_GATEWAY", Node),
    Language = getenv_bin("WHISPER_LANGUAGE", <<"en">>),
    Opts = #{
        <<"priv-wallet">> => Wallet,
        priv_wallet => Wallet,
        <<"http-client">> => httpc,
        http_client => httpc,
        <<"http-retry">> => 0,
        http_retry => 0
    },
    io:format("signer=~s~n", [Address]),
    B0 = balance(Node, Address, Opts),
    io:format("balance_before=~p~n", [B0]),
    {Status, Body} = whisper(Node, TXID, Gateway, Language, Opts),
    B1 = balance(Node, Address, Opts),
    io:format(
        "status=~p~nbody=~s~nbalance_after=~p~ndelta=~p~n",
        [Status, Body, B1, B1 - B0]
    ),
    init:stop().

ensure_apps() ->
    ok = application:ensure_started(crypto),
    ok = application:ensure_started(asn1),
    ok = application:ensure_started(public_key),
    ok = application:ensure_started(ssl),
    ok = application:ensure_started(inets),
    {ok, _} = application:ensure_all_started(prometheus),
    hb_http_client:init_prometheus().

balance(Node, Address, Opts) ->
    Path = <<"/~p4@1.0/balance?target=", Address/binary>>,
    Res = get(Node, Path, Opts),
    to_integer(response_body(Res, Opts)).

whisper(Node, TXID, Gateway, Language, Opts) ->
    Path = <<
        "/~whisper@1.0/transcribe?tx=", TXID/binary,
        "&gateway=", (urlenc(Gateway))/binary,
        "&language=", (urlenc(Language))/binary
    >>,
    Res = get(Node, Path, Opts),
    {hb_maps:get(<<"status">>, Res, undefined, Opts), response_body(Res, Opts)}.

get(Node, Path, Opts) ->
    Msg = hb_message:commit(#{ <<"path">> => Path }, Opts),
    case hb_http:get(Node, Msg, Opts) of
        {ok, Res} -> Res;
        Error ->
            io:format("request_failed path=~s error=~p~n", [Path, Error]),
            init:stop(1),
            receive after infinity -> ok end
    end.

response_body(Res, _Opts) when not is_map(Res) ->
    Res;
response_body(Res, Opts) ->
    case hb_maps:get(<<"body">>, Res, undefined, Opts) of
        undefined -> hb_maps:get(<<"body+link">>, Res, <<>>, Opts);
        Body -> Body
    end.

to_integer(I) when is_integer(I) -> I;
to_integer(B) when is_binary(B) ->
    try binary_to_integer(B)
    catch _:_ ->
        io:format("non_integer_balance=~p~n", [B]),
        init:stop(1),
        receive after infinity -> ok end
    end;
to_integer(Other) ->
    io:format("non_integer_balance=~p~n", [Other]),
    init:stop(1),
    receive after infinity -> ok end.

getenv(Name) ->
    case os:getenv(Name) of
        false ->
            io:format("missing_env=~s~n", [Name]),
            init:stop(64),
            receive after infinity -> ok end;
        Value ->
            Value
    end.

getenv_bin(Name, Default) ->
    case os:getenv(Name) of
        false -> Default;
        Value -> list_to_binary(Value)
    end.

urlenc(Value) ->
    list_to_binary(uri_string:quote(binary_to_list(Value))).
