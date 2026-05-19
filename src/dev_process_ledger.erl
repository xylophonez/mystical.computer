%%% @doc P4 ledger adapter for AO-Core process-backed token ledgers.
%%%
%%% This device reads balances from a configured `process@1.0' ledger and pushes
%%% operator-signed charge messages back into that process.
-module(dev_process_ledger).
-export([balance/3, charge/3]).
-include("include/hb.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

%% @doc Read the target account balance from the configured ledger process.
balance(Base, Req, NodeMsg) ->
    case {ledger_path(Base, NodeMsg), balance_target(Req, NodeMsg)} of
        {undefined, _} ->
            {error, #{
                <<"status">> => 500,
                <<"body">> => <<"Missing process ledger path.">>
            }};
        {_, undefined} ->
            {ok, 0};
        {LedgerPath, Target} ->
            case hb_ao:resolve(
                #{ <<"path">> => <<LedgerPath/binary, "/now/balance/", Target/binary>> },
                NodeMsg
            ) of
                {ok, Balance} -> {ok, Balance};
                {error, _} -> {ok, 0}
            end
    end.

%% @doc Apply a p4 charge by pushing the signed charge request to the ledger.
charge(Base, Req, NodeMsg) ->
    case ledger_path(Base, NodeMsg) of
        undefined ->
            {error, #{
                <<"status">> => 500,
                <<"body">> => <<"Missing process ledger path.">>
            }};
        LedgerPath ->
            hb_ao:resolve(
                #{
                    <<"path">> => <<"(", LedgerPath/binary, ")/push">>,
                    <<"method">> => <<"POST">>,
                    <<"body">> => Req
                },
                NodeMsg
            )
    end.

ledger_path(Base, NodeMsg) ->
    hb_ao:get(<<"ledger-path">>, Base, undefined, NodeMsg).

balance_target(Req, NodeMsg) ->
    case target_from_message(Req, NodeMsg) of
        undefined ->
            case hb_ao:get(<<"request">>, Req, undefined, NodeMsg#{ hashpath => ignore }) of
                undefined -> undefined;
                NestedReq -> target_from_message(NestedReq, NodeMsg)
            end;
        Target ->
            Target
    end.

target_from_message(Msg, NodeMsg) ->
    case normalize_target(hb_ao:get(<<"target">>, Msg, undefined, NodeMsg)) of
        undefined ->
            case hb_message:signers(Msg, NodeMsg) of
                [] -> undefined;
                [Signer | _] -> normalize_target(Signer)
            end;
        Target ->
            Target
    end.

normalize_target(Target) when is_binary(Target) ->
    try hb_util:human_id(Target)
    catch _:_ -> Target
    end;
normalize_target(_) ->
    undefined.

-ifdef(TEST).
missing_ledger_path_test() ->
    ?assertMatch(
        {error, #{ <<"status">> := 500 }},
        balance(#{}, #{ <<"target">> => <<"alice">> }, #{})
    ),
    ?assertMatch(
        {error, #{ <<"status">> := 500 }},
        charge(#{}, #{}, #{})
    ).

missing_balance_target_returns_zero_test() ->
    ?assertEqual(
        {ok, 0},
        balance(#{ <<"ledger-path">> => <<"/missing~process@1.0">> }, #{}, #{})
    ).

missing_ledger_balance_returns_zero_test() ->
    ?assertEqual(
        {ok, 0},
        balance(
            #{ <<"ledger-path">> => <<"/missing~process@1.0">> },
            #{ <<"target">> => <<"alice">> },
            #{}
        )
    ).

explicit_target_balance_test_() ->
    {timeout, 30, fun() ->
        {Base, Opts, AliceAddress, _BobAddress, _HostWallet, _AliceWallet} = test_ledger(100),
        ?assertEqual({ok, 100}, balance(Base, #{ <<"target">> => AliceAddress }, Opts))
    end}.

nested_request_signer_balance_test_() ->
    {timeout, 30, fun() ->
        {Base, Opts, AliceAddress, _BobAddress, _HostWallet, AliceWallet} = test_ledger(100),
        SignedReq =
            hb_message:commit(
                #{ <<"path">> => <<"/paid-route">> },
                #{ <<"priv-wallet">> => AliceWallet }
            ),
        ?assertEqual({ok, 100}, balance(Base, #{ <<"request">> => SignedReq }, Opts)),
        ?assertEqual({ok, AliceAddress}, {ok, hd(hb_message:signers(SignedReq, Opts))})
    end}.

charge_pushes_to_process_ledger_test_() ->
    {timeout, 30, fun() ->
        {Base, Opts, AliceAddress, BobAddress, HostWallet, _AliceWallet} = test_ledger(100),
        ChargeReq =
            hb_message:commit(
                #{
                    <<"path">> => <<"charge">>,
                    <<"quantity">> => 2,
                    <<"account">> => AliceAddress,
                    <<"recipient">> => BobAddress,
                    <<"request">> => #{ <<"path">> => <<"/paid-route">> }
                },
                Opts#{ <<"priv-wallet">> => HostWallet }
            ),
        ?assertMatch({ok, _}, charge(Base, ChargeReq, Opts)),
        ?assertEqual({ok, 98}, balance(Base, #{ <<"target">> => AliceAddress }, Opts)),
        ?assertEqual({ok, 2}, balance(Base, #{ <<"target">> => BobAddress }, Opts))
    end}.

test_ledger(AliceBalance) ->
    Store = hb_test_utils:test_store(),
    HostWallet = ar_wallet:new(),
    AliceWallet = ar_wallet:new(),
    BobWallet = ar_wallet:new(),
    HostAddress = hb_util:human_id(ar_wallet:to_address(HostWallet)),
    AliceAddress = hb_util:human_id(ar_wallet:to_address(AliceWallet)),
    BobAddress = hb_util:human_id(ar_wallet:to_address(BobWallet)),
    Opts = #{
        store => Store,
        <<"store">> => Store,
        priv_wallet => HostWallet,
        <<"priv-wallet">> => HostWallet,
        operator => HostAddress,
        <<"operator">> => HostAddress
    },
    {ok, TokenScript} = file:read_file("scripts/hyper-token.lua"),
    {ok, ProcessScript} = file:read_file("scripts/hyper-token-p4.lua"),
    LedgerProc =
        hb_message:commit(
            #{
                <<"device">> => <<"process@1.0">>,
                <<"type">> => <<"Process">>,
                <<"scheduler-device">> => <<"scheduler@1.0">>,
                <<"scheduler">> => [HostAddress],
                <<"authority">> => [HostAddress],
                <<"admin">> => HostAddress,
                <<"execution-device">> => <<"lua@5.3a">>,
                <<"balance">> => #{ AliceAddress => AliceBalance },
                <<"module">> => [
                    #{
                        <<"content-type">> => <<"text/x-lua">>,
                        <<"name">> => <<"scripts/hyper-token.lua">>,
                        <<"body">> => TokenScript
                    },
                    #{
                        <<"content-type">> => <<"text/x-lua">>,
                        <<"name">> => <<"scripts/hyper-token-p4.lua">>,
                        <<"body">> => ProcessScript
                    }
                ]
            },
            Opts
        ),
    {ok, _} = hb_cache:write(LedgerProc, Opts),
    LedgerID = hb_util:human_id(hb_message:id(LedgerProc, signed, Opts)),
    {
        #{ <<"ledger-path">> => <<"/", LedgerID/binary, "~process@1.0">> },
        Opts,
        AliceAddress,
        BobAddress,
        HostWallet,
        AliceWallet
    }.
-endif.
