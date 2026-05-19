%%% @doc Import verified AO token payments into a local HyperBEAM payment
%%% ledger. This device expects production AO token transfers of the form:
%%%
%%%     Action=Transfer, Recipient=<node deposit address>, Quantity=<raw units>
%%%
%%% It verifies the resulting `Debit-Notice' and `Credit-Notice' from AO
%%% mainnet state before scheduling a local `Credit-Notice' into the configured
%%% ledger process.
-module(dev_ao_payment).
-export([ingest/3, verify/3]).
-include("include/hb.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-define(DEFAULT_AO_TOKEN, <<"0syT13r0s0tgPmIed95bJnuSqaD29HQNN8D3ElLSrsc">>).
-define(DEFAULT_MAINNET_URL, <<"https://state.forward.computer">>).

%% @doc Verify and import an AO token payment into the local ledger.
ingest(Base, Req, NodeMsg) ->
    case verify(Base, Req, NodeMsg) of
        {ok, Payment} ->
            PaymentKey = payment_key(Payment),
            Imports = hb_opts:get(ao_payment_imports, #{}, NodeMsg),
            case maps:find(PaymentKey, Imports) of
                {ok, Existing} ->
                    {ok, Existing#{ <<"status">> => <<"already-imported">> }};
                error ->
                    import_payment(Payment, NodeMsg),
                    NewImports = Imports#{
                        PaymentKey => Payment#{ <<"status">> => <<"imported">> }
                    },
                    hb_http_server:set_opts(
                        #{},
                        NodeMsg#{ <<"ao-payment-imports">> => NewImports }
                    ),
                    {ok, Payment#{ <<"status">> => <<"imported">> }}
            end;
        Error ->
            Error
    end.

%% @doc Verify that an AO message produced matching token debit/credit notices.
verify(_Base, Req, NodeMsg) ->
    Token = hb_ao:get(<<"token">>, Req, hb_opts:get(ao_payment_token, ?DEFAULT_AO_TOKEN, NodeMsg), NodeMsg),
    Ledger = hb_ao:get(<<"ledger">>, Req, hb_opts:get(ao_payment_ledger, undefined, NodeMsg), NodeMsg),
    DepositAddress =
        hb_ao:get(
            <<"deposit-address">>,
            Req,
            hb_opts:get(ao_payment_deposit_address, Ledger, NodeMsg),
            NodeMsg
        ),
    MessageID = hb_ao:get(<<"message-id">>, Req, hb_ao:get(<<"id">>, Req, undefined, NodeMsg), NodeMsg),
    Slot = hb_ao:get(<<"slot">>, Req, undefined, NodeMsg),
    Sender = hb_ao:get(<<"sender">>, Req, undefined, NodeMsg),
    Quantity = hb_util:bin(hb_ao:get(<<"quantity">>, Req, undefined, NodeMsg)),
    RequestedRecipient = hb_ao:get(<<"recipient">>, Req, undefined, NodeMsg),
    case lists:any(fun(V) -> V =:= undefined orelse V =:= <<"undefined">> end,
        [Token, Ledger, DepositAddress, MessageID, Slot, Sender, Quantity])
    of
        true ->
            {error, #{
                <<"status">> => 400,
                <<"body">> => <<"Missing token, ledger, deposit-address, message-id, slot, sender, or quantity.">>
            }};
        false ->
            case fetch_schedule(Token, Slot, NodeMsg) of
                {ok, Result} ->
                    Expected = #{
                        <<"token">> => Token,
                        <<"ledger">> => Ledger,
                        <<"deposit-address">> => DepositAddress,
                        <<"message-id">> => MessageID,
                        <<"slot">> => hb_util:bin(Slot),
                        <<"sender">> => Sender,
                        <<"quantity">> => Quantity,
                        <<"requested-recipient">> => RequestedRecipient
                    },
                    case verify_schedule(Result, Expected, NodeMsg) of
                        ok ->
                            case fetch_result(Token, Slot, NodeMsg) of
                                {ok, ComputeResult} ->
                                    verify_result(ComputeResult, Expected, NodeMsg);
                                {error, Reason} ->
                                    fetch_error(Reason)
                            end;
                        Error ->
                            Error
                    end;
                {error, Reason} ->
                    fetch_error(Reason)
            end
    end.

fetch_schedule(Token, Slot, NodeMsg) ->
    BaseURL = mainnet_url(NodeMsg),
    SlotBin = hb_util:bin(Slot),
    URL =
        <<BaseURL/binary, "/", Token/binary, "~process@1.0/schedule?from=",
            SlotBin/binary, "&to=", SlotBin/binary, "&accept=application/aos-2">>,
    fetch_json(URL).

fetch_result(Token, Slot, NodeMsg) ->
    BaseURL = mainnet_url(NodeMsg),
    SlotBin = hb_util:bin(Slot),
    URL =
        <<BaseURL/binary, "/", Token/binary, "~process@1.0/compute&slot=",
            SlotBin/binary,
            "/results?require-codec=application/json&accept-bundle=true">>,
    fetch_json(URL).

mainnet_url(NodeMsg) ->
    URL0 = hb_opts:get(ao_payment_mainnet_url, ?DEFAULT_MAINNET_URL, NodeMsg),
    case binary:last(URL0) of
            $/ -> binary:part(URL0, 0, byte_size(URL0) - 1);
            _ -> URL0
    end.

fetch_json(URL) ->
    case httpc:request(get, {binary_to_list(URL), [{"accept", "application/json"}]}, [], [{body_format, binary}]) of
        {ok, {{_, 200, _}, _Headers, Body}} ->
            {ok, hb_json:decode(Body)};
        {ok, {{_, Status, _}, _Headers, Body}} ->
            {error, {http_status, Status, Body}};
        {error, Reason} ->
            {error, Reason}
    end.

fetch_error(Reason) ->
    {error, #{
        <<"status">> => 502,
        <<"body">> => <<"Unable to fetch AO payment data from mainnet endpoint.">>,
        <<"reason">> => format_reason(Reason)
    }}.

format_reason(Reason) when is_binary(Reason) -> Reason;
format_reason(Reason) ->
    iolist_to_binary(io_lib:format("~p", [Reason])).

verify_schedule(Schedule, Expected, NodeMsg) ->
    Edges = hb_maps:get(<<"edges">>, Schedule, [], NodeMsg),
    MessageID = hb_maps:get(<<"message-id">>, Expected, undefined, NodeMsg),
    DepositAddress = hb_maps:get(<<"deposit-address">>, Expected, undefined, NodeMsg),
    Quantity = hb_maps:get(<<"quantity">>, Expected, undefined, NodeMsg),
    Slot = hb_maps:get(<<"slot">>, Expected, undefined, NodeMsg),
    Found =
        lists:any(
            fun(Edge) ->
                Node = hb_maps:get(<<"node">>, Edge, #{}, NodeMsg),
                Message = hb_maps:get(<<"message">>, Node, #{}, NodeMsg),
                Assignment = hb_maps:get(<<"assignment">>, Node, #{}, NodeMsg),
                MessageTags = hb_maps:get(<<"Tags">>, Message, [], NodeMsg),
                AssignmentTags = hb_maps:get(<<"Tags">>, Assignment, [], NodeMsg),
                hb_maps:get(<<"Id">>, Message, undefined, NodeMsg) =:= MessageID
                    andalso tag_value(MessageTags, <<"Action">>, NodeMsg) =:= <<"Transfer">>
                    andalso tag_value(MessageTags, <<"Recipient">>, NodeMsg) =:= DepositAddress
                    andalso hb_util:bin(tag_value(MessageTags, <<"Quantity">>, NodeMsg)) =:= Quantity
                    andalso hb_util:bin(tag_value(AssignmentTags, <<"Nonce">>, NodeMsg)) =:= Slot
            end,
            Edges
        ),
    case Found of
        true -> ok;
        false ->
            {error, #{
                <<"status">> => 402,
                <<"body">> => <<"AO schedule did not contain the expected Transfer assignment.">>
            }}
    end.

verify_result(Result, Expected, NodeMsg) ->
    Raw = hb_maps:get(<<"raw">>, Result, Result, NodeMsg),
    Messages = hb_maps:get(<<"Messages">>, Raw, [], NodeMsg),
    DepositAddress = hb_maps:get(<<"deposit-address">>, Expected, undefined, NodeMsg),
    Sender = hb_maps:get(<<"sender">>, Expected, undefined, NodeMsg),
    Quantity = hb_maps:get(<<"quantity">>, Expected, undefined, NodeMsg),
    Debit = find_notice(
        <<"Debit-Notice">>,
        Sender,
        #{<<"Recipient">> => DepositAddress, <<"Quantity">> => Quantity},
        Messages,
        NodeMsg
    ),
    Credit = find_notice(
        <<"Credit-Notice">>,
        DepositAddress,
        #{<<"Sender">> => Sender, <<"Quantity">> => Quantity},
        Messages,
        NodeMsg
    ),
    case {Debit, Credit} of
        {{value, _DebitMsg}, {value, CreditMsg}} ->
            credit_to_payment(CreditMsg, Expected, NodeMsg);
        _ ->
            {error, #{
                <<"status">> => 402,
                <<"body">> => <<"AO result did not contain the expected Debit-Notice and Credit-Notice.">>
            }}
    end.

find_notice(Action, Target, RequiredTags, Messages, NodeMsg) ->
    lists:search(
        fun(Msg) ->
            Tags = hb_maps:get(<<"Tags">>, Msg, [], NodeMsg),
            hb_maps:get(<<"Target">>, Msg, undefined, NodeMsg) =:= Target
                andalso tag_value(Tags, <<"Action">>, NodeMsg) =:= Action
                andalso maps:fold(
                    fun(Name, Value, Acc) ->
                        Acc andalso hb_util:bin(tag_value(Tags, Name, NodeMsg)) =:= Value
                    end,
                    true,
                    RequiredTags
                )
        end,
        Messages
    ).

credit_to_payment(CreditMsg, Expected, NodeMsg) ->
    Tags = hb_maps:get(<<"Tags">>, CreditMsg, [], NodeMsg),
    Sender = hb_maps:get(<<"sender">>, Expected, undefined, NodeMsg),
    RequestedRecipient = hb_maps:get(<<"requested-recipient">>, Expected, undefined, NodeMsg),
    Recipient =
        case tag_value(Tags, <<"X-HB-Recipient">>, NodeMsg) of
            undefined -> Sender;
            ForwardedRecipient -> ForwardedRecipient
        end,
    case RequestedRecipient =:= undefined orelse RequestedRecipient =:= Recipient of
        true ->
            {ok, #{
                <<"token">> => hb_maps:get(<<"token">>, Expected, undefined, NodeMsg),
                <<"message-id">> => hb_maps:get(<<"message-id">>, Expected, undefined, NodeMsg),
                <<"ledger">> => hb_maps:get(<<"ledger">>, Expected, undefined, NodeMsg),
                <<"sender">> => Sender,
                <<"recipient">> => Recipient,
                <<"quantity">> => hb_maps:get(<<"quantity">>, Expected, undefined, NodeMsg),
                <<"notice-reference">> => tag_value(Tags, <<"Reference">>, NodeMsg)
            }};
        false ->
            {error, #{
                <<"status">> => 400,
                <<"body">> => <<"Requested recipient does not match AO Credit-Notice.">>,
                <<"recipient">> => Recipient
            }}
    end.

import_payment(Payment, NodeMsg) ->
    Wallet =
        case hb_opts:get(priv_wallet, not_found, NodeMsg) of
            not_found ->
                hb:wallet(hb_opts:get(priv_key_location, <<"hyperbeam-key.json">>, NodeMsg));
            FoundWallet ->
                FoundWallet
        end,
    Operator = hb_util:human_id(ar_wallet:to_address(Wallet)),
    Opts = NodeMsg#{
        priv_wallet => Wallet,
        <<"priv-wallet">> => Wallet,
        operator => Operator,
        <<"operator">> => Operator
    },
    Ledger = hb_maps:get(<<"ledger">>, Payment, undefined, NodeMsg),
    LedgerRoute = <<"/", Ledger/binary, "~process@1.0">>,
    CreditNotice =
        hb_message:commit(
            #{
                <<"target">> => Ledger,
                <<"type">> => <<"Message">>,
                <<"action">> => <<"Credit-Notice">>,
                <<"from-process">> => hb_maps:get(<<"token">>, Payment, undefined, NodeMsg),
                <<"recipient">> => hb_maps:get(<<"recipient">>, Payment, undefined, NodeMsg),
                <<"quantity">> => hb_util:int(hb_maps:get(<<"quantity">>, Payment, undefined, NodeMsg)),
                <<"sender">> => hb_maps:get(<<"sender">>, Payment, undefined, NodeMsg),
                <<"ao-payment-id">> => hb_maps:get(<<"message-id">>, Payment, undefined, NodeMsg)
            },
            Opts
        ),
    Node = local_node(NodeMsg),
    {ok, _} =
        hb_http:post(
            Node,
            <<LedgerRoute/binary, "/schedule">>,
            CreditNotice,
            Opts
        ),
    ok.

local_node(NodeMsg) ->
    hb_opts:get(
        ao_payment_node,
        <<"http://localhost:", (hb_util:bin(hb_opts:get(port, 8734, NodeMsg)))/binary>>,
        NodeMsg
    ).

payment_key(Payment) ->
    <<(hb_maps:get(<<"token">>, Payment, undefined, #{}))/binary, ":",
        (hb_maps:get(<<"message-id">>, Payment, undefined, #{}))/binary>>.

tag_value(Tags, Name, NodeMsg) ->
    case lists:search(
        fun(Tag) ->
            hb_maps:get(<<"name">>, Tag, undefined, NodeMsg) =:= Name
        end,
        Tags
    ) of
        {value, Tag} -> hb_maps:get(<<"value">>, Tag, undefined, NodeMsg);
        false -> undefined
    end.

-ifdef(TEST).
verify_result_requires_debit_and_credit_test() ->
    Expected = #{
        <<"token">> => <<"ao-token">>,
        <<"message-id">> => <<"message-id">>,
        <<"ledger">> => <<"ledger">>,
        <<"deposit-address">> => <<"node-address">>,
        <<"sender">> => <<"sender">>,
        <<"quantity">> => <<"1">>,
        <<"requested-recipient">> => undefined
    },
    Debit = #{
        <<"Target">> => <<"sender">>,
        <<"Tags">> => [
            #{<<"name">> => <<"Action">>, <<"value">> => <<"Debit-Notice">>},
            #{<<"name">> => <<"Recipient">>, <<"value">> => <<"node-address">>},
            #{<<"name">> => <<"Quantity">>, <<"value">> => <<"1">>}
        ]
    },
    Credit = #{
        <<"Target">> => <<"node-address">>,
        <<"Tags">> => [
            #{<<"name">> => <<"Action">>, <<"value">> => <<"Credit-Notice">>},
            #{<<"name">> => <<"Sender">>, <<"value">> => <<"sender">>},
            #{<<"name">> => <<"Quantity">>, <<"value">> => <<"1">>}
        ]
    },
    ?assertMatch(
        {ok, #{ <<"recipient">> := <<"sender">>, <<"quantity">> := <<"1">> }},
        verify_result(#{<<"raw">> => #{<<"Messages">> => [Debit, Credit]}}, Expected, #{})
    ),
    ?assertMatch(
        {error, #{ <<"status">> := 402 }},
        verify_result(#{<<"raw">> => #{<<"Messages">> => [Credit]}}, Expected, #{})
    ).

verify_rejects_missing_required_fields_test() ->
    ?assertMatch(
        {error, #{ <<"status">> := 400 }},
        verify(#{}, #{ <<"message-id">> => <<"message-id">> }, #{})
    ).

verify_schedule_matches_expected_transfer_test() ->
    Schedule = #{
        <<"edges">> => [
            #{
                <<"node">> => #{
                    <<"message">> => #{
                        <<"Id">> => <<"message-id">>,
                        <<"Tags">> => [
                            tag(<<"Action">>, <<"Transfer">>),
                            tag(<<"Recipient">>, <<"node-address">>),
                            tag(<<"Quantity">>, <<"1">>)
                        ]
                    },
                    <<"assignment">> => #{
                        <<"Tags">> => [tag(<<"Nonce">>, <<"7">>)]
                    }
                }
            }
        ]
    },
    Expected = #{
        <<"message-id">> => <<"message-id">>,
        <<"ledger">> => <<"ledger">>,
        <<"deposit-address">> => <<"node-address">>,
        <<"quantity">> => <<"1">>,
        <<"slot">> => <<"7">>
    },
    ?assertEqual(ok, verify_schedule(Schedule, Expected, #{})),
    ?assertMatch(
        {error, #{ <<"status">> := 402 }},
        verify_schedule(
            Schedule,
            Expected#{ <<"quantity">> => <<"2">> },
            #{}
        )
    ).

credit_to_payment_uses_sender_without_forwarded_recipient_test() ->
    Expected = payment_expected(undefined),
    Credit = credit_notice([]),
    ?assertMatch(
        {ok, #{ <<"recipient">> := <<"sender">> }},
        credit_to_payment(Credit, Expected, #{})
    ).

credit_to_payment_respects_forwarded_recipient_test() ->
    Expected = payment_expected(<<"local-recipient">>),
    Credit = credit_notice([tag(<<"X-HB-Recipient">>, <<"local-recipient">>)]),
    ?assertMatch(
        {ok, #{ <<"recipient">> := <<"local-recipient">> }},
        credit_to_payment(Credit, Expected, #{})
    ).

credit_to_payment_rejects_requested_recipient_mismatch_test() ->
    Expected = payment_expected(<<"local-recipient">>),
    Credit = credit_notice([tag(<<"X-HB-Recipient">>, <<"other-recipient">>)]),
    ?assertMatch(
        {error, #{ <<"status">> := 400 }},
        credit_to_payment(Credit, Expected, #{})
    ).

payment_expected(RequestedRecipient) ->
    #{
        <<"token">> => <<"ao-token">>,
        <<"message-id">> => <<"message-id">>,
        <<"ledger">> => <<"ledger">>,
        <<"deposit-address">> => <<"node-address">>,
        <<"sender">> => <<"sender">>,
        <<"quantity">> => <<"1">>,
        <<"requested-recipient">> => RequestedRecipient
    }.

credit_notice(ExtraTags) ->
    #{
        <<"Tags">> => [
            tag(<<"Reference">>, <<"notice-reference">>)
            | ExtraTags
        ]
    }.

tag(Name, Value) ->
    #{ <<"name">> => Name, <<"value">> => Value }.
-endif.
