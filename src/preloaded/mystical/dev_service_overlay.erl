%%% @doc Generic AO/P4 paid-route overlay for HyperBEAM service nodes.
%%%
%%% The overlay prepares a local AO-token ledger process, installs P4
%%% request/response hooks, and exposes a small status/activation API. Operators
%%% can then charge AO-denominated ledger balances for routes such as
%%% `~whisper@1.0' by adding `router-opts/offered' prices.
-module(dev_service_overlay).
-implements(<<"service-overlay@1.0">>).
-export([info/1, start/3, activate/3, request/3, response/3, status/3]).

-include("include/hb.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-define(AO_TOKEN, <<"0syT13r0s0tgPmIed95bJnuSqaD29HQNN8D3ElLSrsc">>).
-define(DEFAULT_LEDGER_NAME, <<"ledger">>).

info(_) ->
    #{ exports => [<<"start">>, <<"activate">>, <<"request">>, <<"response">>, <<"status">>] }.

%% @doc Start hook entrypoint. Returns the updated node message under `body'.
start(Base, HookMsg = #{ <<"body">> := NodeMsg0 }, _Opts) ->
    case enabled(Base, NodeMsg0, true) of
        false ->
            {ok, HookMsg};
        true ->
            case configure(NodeMsg0, overlay_device_ref(Base)) of
                {ok, NodeMsg} -> {ok, HookMsg#{ <<"body">> => NodeMsg }};
                Error -> Error
            end
    end.

%% @doc Runtime activation endpoint. Useful for interactive shells/tests; prefer
%% the `start' hook for production so the first paid request is protected.
activate(Base, _Req, Opts) ->
    case configure(Opts, overlay_device_ref(Base)) of
        {ok, NodeMsg} ->
            ok = hb_http_server:set_opts(NodeMsg),
            status(Base, #{}, NodeMsg);
        Error ->
            Error
    end.

%% @doc Request hook. When installed by `start/3', this wraps P4 so
%% `~p4@1.0/balance' can still discover a single request hook. When used as a
%% lazy hook before activation, it configures the overlay for subsequent calls.
request(State, Raw, Opts) ->
    case maps:is_key(<<"ledger-path">>, State) of
        true ->
            case maybe_manifest_request(State, Raw, Opts) of
                {ok, HookReq} ->
                    call_device(
                        maps:get(<<"p4-device">>, State, <<"p4@1.0">>),
                        request,
                        [p4_state(State), HookReq, Opts],
                        Opts
                    );
                Error ->
                    Error
            end;
        false ->
            maybe_lazy_activate(State, Raw, Opts)
    end.

response(State, RawResponse, Opts) ->
    case maps:is_key(<<"ledger-path">>, State) of
        true ->
            call_device(
                maps:get(<<"p4-device">>, State, <<"p4@1.0">>),
                response,
                [p4_state(State), RawResponse, Opts],
                Opts
            );
        false -> {ok, RawResponse}
    end.

status(_Base, _Req, Opts) ->
    Address = node_address(Opts),
    LedgerName = ledger_name(Opts),
    {ok, #{
        <<"status">> => 200,
        <<"body">> => #{
            <<"active">> => active(Opts),
            <<"deposit-address">> =>
                hb_opts:get(ao_payment_deposit_address, Address, Opts),
            <<"beneficiary">> => beneficiary_address(Opts, Address),
            <<"ledger-name">> => LedgerName,
            <<"ledger">> => hb_opts:get(ao_payment_ledger, LedgerName, Opts),
            <<"ledger-path">> => ledger_path(LedgerName),
            <<"token">> => hb_opts:get(ao_payment_token, ?AO_TOKEN, Opts)
        }
    }}.

maybe_lazy_activate(State, Raw, Opts) ->
    case {enabled(State, Opts, false), active(Opts)} of
        {true, false} ->
            case configure(Opts, overlay_device_ref(State)) of
                {ok, NodeMsg} ->
                    ok = hb_http_server:set_opts(NodeMsg),
                    {ok, Raw};
                Error ->
                    Error
            end;
        _ ->
            {ok, Raw}
    end.

enabled(Base, NodeMsg, Default) ->
    enabled_value(
        hb_maps:get(
            <<"enabled">>,
            Base,
            hb_maps:get(<<"service-overlay">>, NodeMsg, Default, NodeMsg),
            NodeMsg
        )
    ).

enabled_value(false) -> false;
enabled_value(<<"false">>) -> false;
enabled_value(0) -> false;
enabled_value(<<"0">>) -> false;
enabled_value(_) -> true.

active(Opts) ->
    case hb_opts:get(service_overlay_active, false, Opts) of
        true -> true;
        <<"true">> -> true;
        1 -> true;
        <<"1">> -> true;
        _ -> false
    end.

configure(NodeMsg0, OverlayDevice) ->
    Address = node_address(NodeMsg0),
    Beneficiary = beneficiary_address(NodeMsg0, Address),
    Recipient = p4_recipient(NodeMsg0, Beneficiary),
    LedgerName = ledger_name(NodeMsg0),
    case ledger_process(Address, NodeMsg0) of
        {ok, LedgerProc} ->
            NodeMsg1 =
                install_base_config(
                    NodeMsg0,
                    Address,
                    Beneficiary,
                    Recipient,
                    LedgerName,
                    LedgerProc
                ),
            case ensure_ledger(NodeMsg1, LedgerName) of
                {ok, LedgerID} ->
                    {ok,
                        install_hooks(
                            NodeMsg1,
                            Beneficiary,
                            Recipient,
                            LedgerName,
                            LedgerID,
                            OverlayDevice
                        )};
                {error, Reason} ->
                    overlay_error(
                        <<"Failed to spawn service overlay payment ledger.">>,
                        Reason
                    )
            end;
        {error, Reason} ->
            overlay_error(<<"Failed to prepare service overlay ledger.">>, Reason)
    end.

overlay_error(Body, Reason) ->
    {error, #{
        <<"status">> => 500,
        <<"body">> => Body,
        <<"reason">> => hb_util:bin(io_lib:format("~0p", [Reason]))
    }}.

node_address(NodeMsg) ->
    case hb_maps:get(<<"address">>, NodeMsg, undefined, NodeMsg) of
        undefined ->
            Wallet =
                case hb_opts:get(priv_wallet, undefined, NodeMsg) of
                    undefined ->
                        hb:wallet(
                            hb_opts:get(
                                priv_key_location,
                                <<"hyperbeam-key.json">>,
                                NodeMsg
                            )
                        );
                    FoundWallet ->
                        FoundWallet
                end,
            hb_util:human_id(ar_wallet:to_address(Wallet));
        Address ->
            hb_util:human_id(Address)
    end.

beneficiary_address(NodeMsg, Default) ->
    normalize_address(
        first_defined(
            [
                hb_maps:get(<<"service-overlay-beneficiary">>, NodeMsg, undefined, NodeMsg),
                hb_maps:get(<<"bundler-beneficiary">>, NodeMsg, undefined, NodeMsg),
                hb_maps:get(<<"p4-recipient">>, NodeMsg, undefined, NodeMsg)
            ],
            Default
        )
    ).

p4_recipient(NodeMsg, Default) ->
    normalize_address(
        first_defined(
            [
                hb_maps:get(<<"service-overlay-p4-recipient">>, NodeMsg, undefined, NodeMsg),
                hb_maps:get(<<"p4-recipient">>, NodeMsg, undefined, NodeMsg)
            ],
            Default
        )
    ).

first_defined([], Default) ->
    Default;
first_defined([undefined | Rest], Default) ->
    first_defined(Rest, Default);
first_defined([<<>> | Rest], Default) ->
    first_defined(Rest, Default);
first_defined([Value | _], _Default) ->
    Value.

normalize_address(Address) when ?IS_ID(Address) ->
    hb_util:human_id(Address);
normalize_address(Address) ->
    Address.

ledger_name(NodeMsg) ->
    hb_util:bin(
        first_defined(
            [
                hb_maps:get(<<"service-overlay-ledger">>, NodeMsg, undefined, NodeMsg),
                hb_maps:get(<<"ao-payment-ledger-name">>, NodeMsg, undefined, NodeMsg),
                hb_maps:get(<<"ao-payment-ledger">>, NodeMsg, undefined, NodeMsg)
            ],
            ?DEFAULT_LEDGER_NAME
        )
    ).

ledger_path(LedgerName) ->
    <<"/", LedgerName/binary, "~node-process@1.0">>.

ledger_process(Address, NodeMsg) ->
    try
        {ok, TokenScript} = read_script("hyper-token.lua"),
        {ok, P4Script} = read_script("hyper-token-p4.lua"),
        {ok, #{
            <<"device">> => <<"process@1.0">>,
            <<"type">> => <<"Process">>,
            <<"execution-device">> => <<"lua@5.3a">>,
            <<"scheduler-device">> => <<"scheduler@1.0">>,
            <<"scheduler">> => [Address],
            <<"authority">> => [Address],
            <<"admin">> => Address,
            <<"token">> => hb_opts:get(ao_payment_token, ?AO_TOKEN, NodeMsg),
            <<"balance">> => #{},
            <<"module">> => [
                #{
                    <<"content-type">> => <<"text/x-lua">>,
                    <<"name">> => <<"scripts/hyper-token.lua">>,
                    <<"body">> => TokenScript
                },
                #{
                    <<"content-type">> => <<"text/x-lua">>,
                    <<"name">> => <<"scripts/hyper-token-p4.lua">>,
                    <<"body">> => P4Script
                }
            ]
        }}
    catch
        Class:CatchReason:Stack ->
            {error, {Class, CatchReason, Stack}}
    end.

ensure_ledger(NodeMsg, LedgerName) ->
    try
        case hb_ao:resolve(
            #{ <<"device">> => <<"node-process@1.0">> },
            LedgerName,
            NodeMsg
        ) of
            {ok, LedgerMsg} ->
                {ok, hb_util:human_id(hb_message:id(LedgerMsg, signed, NodeMsg))};
            {error, Reason} ->
                {error, Reason}
        end
    catch
        Class:CatchReason:Stack ->
            {error, {Class, CatchReason, Stack}}
    end.

read_script(Name) ->
    read_first(script_paths(Name), []).

script_paths(Name) ->
    NameBin = hb_util:bin(Name),
    NameList = binary_to_list(NameBin),
    ImplementationDir = hb_device_archive:implementation_dir(?MODULE),
    PrivCandidates =
        case code:priv_dir(hb) of
            {error, _} -> [];
            Priv ->
                [
                    filename:join([Priv, "service-overlay", NameList]),
                    filename:join([Priv, "lapee-p4", NameList])
                ]
        end,
    [
        filename:join([ImplementationDir, "service-overlay", NameList])
        | PrivCandidates
    ] ++ [
        filename:join(["priv", "service-overlay", NameList]),
        filename:join(["priv", "lapee-p4", NameList]),
        filename:join(["scripts", NameList])
    ].

read_first([], Errors) ->
    {error, {missing_script, lists:reverse(Errors)}};
read_first([Path | Rest], Errors) ->
    case file:read_file(Path) of
        {ok, Body} -> {ok, Body};
        {error, Reason} -> read_first(Rest, [{Path, Reason} | Errors])
    end.

install_base_config(
        NodeMsg0,
        Address,
        Beneficiary,
        Recipient,
        LedgerName,
        LedgerProc
    ) ->
    NodeProcesses0 = map_opt(<<"node-processes">>, NodeMsg0),
    NodeMsg0#{
        <<"operator">> => Address,
        <<"p4-recipient">> => Recipient,
        <<"bundler-beneficiary">> => Beneficiary,
        <<"ao-payment-token">> => hb_opts:get(ao_payment_token, ?AO_TOKEN, NodeMsg0),
        <<"ao-payment-deposit-address">> =>
            hb_opts:get(ao_payment_deposit_address, Address, NodeMsg0),
        <<"ao-payment-mainnet-url">> =>
            hb_opts:get(
                ao_payment_mainnet_url,
                <<"https://state.forward.computer">>,
                NodeMsg0
            ),
        <<"ao-payment-node">> =>
            hb_opts:get(
                ao_payment_node,
                <<"http://localhost:",
                    (hb_util:bin(hb_maps:get(<<"port">>, NodeMsg0, 8734, NodeMsg0)))/binary>>,
                NodeMsg0
            ),
        <<"simple-pay-price">> => hb_opts:get(simple_pay_price, 0, NodeMsg0),
        <<"node-processes">> => NodeProcesses0#{ LedgerName => LedgerProc }
    }.

install_hooks(
        NodeMsg0,
        Beneficiary,
        Recipient,
        LedgerName,
        LedgerID,
        OverlayDevice
    ) ->
    DeviceRefs = service_device_refs(NodeMsg0, OverlayDevice),
    LedgerPath = ledger_path(LedgerName),
    Processor = p4_processor(NodeMsg0, LedgerPath, DeviceRefs),
    Request = request_processor(
        maps:get(<<"request">>, map_opt(<<"on">>, NodeMsg0), []),
        Processor,
        OverlayDevice
    ),
    On0 = map_opt(<<"on">>, NodeMsg0),
    On1 = On0#{
        <<"request">> => Request,
        <<"response">> =>
            append_hook_handlers(
                without_device(
                    maps:get(<<"response">>, On0, []),
                    <<"p4@1.0">>
                ),
                [Processor]
            ),
        <<"bundled-message-complete">> =>
            maybe_bundler_settlement(
                NodeMsg0,
                maps:get(<<"bundled-message-complete">>, On0, []),
                bundler_settlement(Recipient, Beneficiary, LedgerPath, DeviceRefs)
            )
    },
    LocalNames0 = map_opt(<<"local-names">>, NodeMsg0),
    NodeMsg0#{
        <<"ao-payment-ledger">> => LedgerID,
        <<"service-overlay-ledger">> => LedgerName,
        <<"local-names">> => LocalNames0#{ LedgerName => LedgerID },
        <<"p4-non-chargable-routes">> =>
            merge_routes(
                list_opt(<<"p4-non-chargable-routes">>, NodeMsg0),
                p4_non_chargable_routes(LedgerName, LedgerID)
            ),
        <<"on">> => On1,
        <<"service-overlay-active">> => true,
        <<"service-overlay-activated-at-unix">> => erlang:system_time(second)
    }.

request_processor(ExistingRequest, Processor, OverlayDevice) ->
    Base = Processor#{
        <<"device">> => OverlayDevice,
        <<"p4-device">> => <<"p4@1.0">>
    },
    case find_manifest_request(ExistingRequest) of
        not_found -> Base;
        ManifestRequest -> Base#{ <<"manifest-request">> => ManifestRequest }
    end.

maybe_bundler_settlement(NodeMsg, Existing, Settlement) ->
    case enabled_value(
        hb_maps:get(<<"service-overlay-bundler-settlement">>, NodeMsg, false, NodeMsg)
    ) of
        true ->
            append_hook_handlers(
                without_device(Existing, maps:get(<<"device">>, Settlement)),
                [Settlement]
            );
        false ->
            Existing
    end.

append_hook_handlers([], NewHandlers) ->
    NewHandlers;
append_hook_handlers(Existing, NewHandlers) when is_list(Existing) ->
    Existing ++ NewHandlers;
append_hook_handlers(Existing, NewHandlers) ->
    [Existing | NewHandlers].

without_device(Handlers, Device) ->
    [
        Handler
        || Handler <- hook_handlers(Handlers),
           hb_maps:get(<<"device">>, Handler, undefined, Handler) =/= Device
    ].

find_manifest_request(ExistingRequest) ->
    find_manifest_request_1(hook_handlers(ExistingRequest)).

find_manifest_request_1([]) ->
    not_found;
find_manifest_request_1([Handler = #{ <<"device">> := <<"manifest@1.0">> } | _]) ->
    Handler;
find_manifest_request_1([_ | Rest]) ->
    find_manifest_request_1(Rest).

hook_handlers([]) ->
    [];
hook_handlers(Handler) when is_map(Handler) ->
    case hb_util:is_ordered_list(Handler, Handler) of
        true -> hb_util:message_to_ordered_list(Handler, Handler);
        false -> [Handler]
    end;
hook_handlers(Handlers) when is_list(Handlers) ->
    Handlers;
hook_handlers(_) ->
    [].

maybe_manifest_request(State, Raw, Opts) ->
    case {manifest_request(State), should_manifest_request(Raw, Opts)} of
        {false, _} ->
            {ok, Raw};
        {_, false} ->
            {ok, Raw};
        {ManifestRequest, true} ->
            Device = maps:get(<<"device">>, ManifestRequest, <<"manifest@1.0">>),
            case call_device(Device, request, [ManifestRequest, Raw, Opts], Opts) of
                {error, #{ <<"status">> := 404 }} -> {ok, Raw};
                Other -> Other
            end
    end.

call_device(Device, Function, Args, Opts) ->
    {ok, Module} = hb_device_load:reference(Device, Opts),
    apply(Module, Function, Args).

manifest_request(State) ->
    case maps:get(<<"manifest-request">>, State, false) of
        Handler when is_map(Handler) -> Handler;
        _ -> false
    end.

should_manifest_request(Raw, Opts) ->
    Request = hb_maps:get(<<"request">>, Raw, #{}, Opts),
    Method = hb_maps:get(<<"method">>, Request, <<"GET">>, Opts),
    Path = hb_maps:get(<<"path">>, Request, <<>>, Opts),
    is_read_method(Method) andalso manifest_candidate_path(Path).

is_read_method(Method) ->
    case string:uppercase(binary_to_list(hb_util:bin(Method))) of
        "GET" -> true;
        "HEAD" -> true;
        _ -> false
    end.

manifest_candidate_path(Path0) ->
    Path = path_only(hb_util:bin(Path0)),
    case binary:split(trim_leading_slash(Path), <<"/">>) of
        [<<>>] -> false;
        [First | _] when ?IS_ID(First) -> true;
        _ -> false
    end.

path_only(Path) ->
    case binary:split(Path, <<"?">>) of
        [Only] -> Only;
        [Only, _Query] -> Only
    end.

trim_leading_slash(<<"/", Rest/binary>>) ->
    Rest;
trim_leading_slash(Path) ->
    Path.

p4_state(State) ->
    P4Device = maps:get(<<"p4-device">>, State, <<"p4@1.0">>),
    maps:without(
        [<<"manifest-request">>, <<"p4-device">>],
        State#{ <<"device">> => P4Device }
    ).

overlay_device_ref(Base) when is_map(Base) ->
    maps:get(<<"device">>, Base, <<"service-overlay@1.0">>);
overlay_device_ref(_) ->
    <<"service-overlay@1.0">>.

service_device_refs(NodeMsg, OverlayDevice) ->
    #{
        <<"ao-payment@1.0">> => device_ref(<<"ao-payment@1.0">>, NodeMsg),
        <<"arweave-byte-pricing@1.0">> =>
            device_ref(<<"arweave-byte-pricing@1.0">>, NodeMsg),
        <<"bundler-settlement@1.0">> =>
            device_ref(<<"bundler-settlement@1.0">>, NodeMsg),
        <<"pricing-router@1.0">> => device_ref(<<"pricing-router@1.0">>, NodeMsg),
        <<"process-ledger@1.0">> => device_ref(<<"process-ledger@1.0">>, NodeMsg),
        <<"service-overlay@1.0">> => OverlayDevice,
        <<"simple-oracle@1.0">> => device_ref(<<"simple-oracle@1.0">>, NodeMsg)
    }.

device_ref(Name, NodeMsg) ->
    device_ref_1(Name, list_opt(<<"name-resolvers">>, NodeMsg), NodeMsg).

device_ref_1(Name, [Resolver | Rest], Opts) when is_map(Resolver) ->
    case hb_maps:get(Name, Resolver, not_found, Opts) of
        not_found -> device_ref_1(Name, Rest, Opts);
        Ref -> Ref
    end;
device_ref_1(Name, [_ | Rest], Opts) ->
    device_ref_1(Name, Rest, Opts);
device_ref_1(Name, [], _Opts) ->
    Name.

map_opt(Key, NodeMsg) ->
    case hb_maps:get(Key, NodeMsg, #{}, NodeMsg) of
        Value when is_map(Value) -> Value;
        _ -> #{}
    end.

list_opt(Key, NodeMsg) ->
    case hb_maps:get(Key, NodeMsg, [], NodeMsg) of
        Value when is_list(Value) -> Value;
        Value when is_map(Value) ->
            case hb_util:is_ordered_list(Value, NodeMsg) of
                true -> hb_util:message_to_ordered_list(Value, NodeMsg);
                false -> []
            end;
        _ -> []
    end.

p4_processor(NodeMsg, LedgerPath, DeviceRefs) ->
    #{
        <<"device">> => <<"p4@1.0">>,
        <<"ledger-device">> => maps:get(<<"process-ledger@1.0">>, DeviceRefs),
        <<"pricing-device">> => maps:get(<<"pricing-router@1.0">>, DeviceRefs),
        <<"default-pricing-device">> => <<"simple-pay@1.0">>,
        <<"ledger-path">> => LedgerPath,
        <<"pricing-routes">> => pricing_routes(NodeMsg, DeviceRefs)
    }.

pricing_routes(NodeMsg, DeviceRefs) ->
    Configured = list_opt(<<"service-overlay-pricing-routes">>, NodeMsg),
    case {
        Configured,
        enabled_value(
            hb_maps:get(<<"service-overlay-paid-bundler">>, NodeMsg, false, NodeMsg)
        )
    } of
        {[], true} -> bundler_pricing_routes(DeviceRefs);
        {Routes, true} -> Routes ++ bundler_pricing_routes(DeviceRefs);
        {Routes, false} -> Routes
    end.

bundler_pricing_routes(DeviceRefs) ->
    [
        #{
            <<"template">> => <<"/~bundler@1.0/tx">>,
            <<"pricing-device">> => maps:get(<<"arweave-byte-pricing@1.0">>, DeviceRefs)
        },
        #{
            <<"template">> => <<"/~bundler@1.0/item">>,
            <<"pricing-device">> => maps:get(<<"arweave-byte-pricing@1.0">>, DeviceRefs)
        }
    ].

bundler_settlement(Account, Beneficiary, LedgerPath, DeviceRefs) ->
    #{
        <<"device">> => maps:get(<<"bundler-settlement@1.0">>, DeviceRefs),
        <<"ledger-device">> => maps:get(<<"process-ledger@1.0">>, DeviceRefs),
        <<"pricing-device">> => maps:get(<<"arweave-byte-pricing@1.0">>, DeviceRefs),
        <<"ledger-path">> => LedgerPath,
        <<"settlement-account">> => Account,
        <<"beneficiary">> => Beneficiary,
        <<"hook">> => #{ <<"result">> => <<"ignore">> }
    }.

p4_non_chargable_routes(LedgerName, LedgerID) ->
    LedgerPath = ledger_path(LedgerName),
    [
        #{ <<"template">> => <<"/*~node-process@1.0/*">> },
        #{ <<"template">> => <<LedgerPath/binary, "/*">> },
        #{ <<"template">> => <<"/", LedgerID/binary, "~process@1.0/*">> },
        #{ <<"template">> => <<"^/[A-Za-z0-9_-]{43}$">> },
        #{ <<"template">> => <<"^/[A-Za-z0-9_-]{43}/.*$">> },
        #{ <<"template">> => <<"/~ao-payment@1.0/*">> },
        #{ <<"template">> => <<"/~service-overlay@1.0/*">> },
        #{ <<"template">> => <<"/~p4@1.0/balance">> },
        #{ <<"template">> => <<"/~p4@1.0/topup">> },
        #{ <<"template">> => <<"/~manifest@1.0/*">> },
        #{ <<"template">> => <<"/~meta@1.0/*">> },
        #{ <<"template">> => <<"/~query@1.0/*">> },
        #{ <<"template">> => <<"/~hyperbuddy@1.0/*">> },
        #{ <<"template">> => <<"/graphql">> },
        #{ <<"template">> => <<"/schedule">> }
    ].

merge_routes(Existing, Defaults) ->
    Existing ++ [
        Route
        || Route <- Defaults,
           not lists:any(
               fun(ExistingRoute) -> same_template(ExistingRoute, Route) end,
               Existing
           )
    ].

same_template(A, B) ->
    maps:get(<<"template">>, A, undefined) =:= maps:get(<<"template">>, B, undefined).

-ifdef(TEST).

start_installs_overlay_hooks_test_() ->
    {timeout, 30, fun() ->
        Wallet = ar_wallet:new(),
        Address = hb_util:human_id(ar_wallet:to_address(Wallet)),
        Store = hb_test_utils:test_store(),
        NodeMsg0 = #{
            <<"priv-wallet">> => Wallet,
            <<"store">> => Store,
            <<"router-opts">> => #{
                <<"offered">> => [
                    #{
                        <<"template">> => <<"/~whisper@1.0/.*">>,
                        <<"price">> => 10
                    }
                ]
            }
        },
        {ok, #{ <<"body">> := NodeMsg }} =
            start(#{}, #{ <<"body">> => NodeMsg0 }, #{}),
        On = maps:get(<<"on">>, NodeMsg),
        RequestHook = maps:get(<<"request">>, On),
        ?assertEqual(<<"service-overlay@1.0">>, maps:get(<<"device">>, RequestHook)),
        ?assertEqual(<<"process-ledger@1.0">>, maps:get(<<"ledger-device">>, RequestHook)),
        ?assertEqual(<<"pricing-router@1.0">>, maps:get(<<"pricing-device">>, RequestHook)),
        ?assertEqual(0, maps:get(<<"simple-pay-price">>, NodeMsg)),
        ?assertEqual(Address, maps:get(<<"ao-payment-deposit-address">>, NodeMsg)),
        ?assert(maps:is_key(<<"ledger">>, maps:get(<<"local-names">>, NodeMsg))),
        ?assertEqual(true, maps:get(<<"service-overlay-active">>, NodeMsg))
    end}.

paid_bundler_routes_are_opt_in_test() ->
    Wallet = ar_wallet:new(),
    Store = hb_test_utils:test_store(),
    Base = #{
        <<"priv-wallet">> => Wallet,
        <<"store">> => Store,
        <<"service-overlay-paid-bundler">> => true
    },
    {ok, #{ <<"body">> := NodeMsg }} =
        start(#{}, #{ <<"body">> => Base }, #{}),
    RequestHook = maps:get(<<"request">>, maps:get(<<"on">>, NodeMsg)),
    Routes = hb_maps:get(<<"pricing-routes">>, RequestHook),
    ?assertMatch(
        [#{ <<"template">> := <<"/~bundler@1.0/tx">> } | _],
        Routes
    ).

-endif.
