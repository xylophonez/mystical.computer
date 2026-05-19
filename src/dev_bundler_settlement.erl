%%% @doc Completion hook for settling paid bundler uploads.
%%%
%%% P4 charges the uploader when the bundler POST succeeds. This hook runs after
%%% bundle completion and moves the metered fee from the node's local ledger
%%% account to the beneficiary/operator account.
-module(dev_bundler_settlement).
-export([info/1, bundled_message_complete/3, bundle_complete/3]).

-include("include/hb.hrl").

info(_) ->
    #{ exports => [<<"bundled-message-complete">>, <<"bundle-complete">>] }.

bundled_message_complete(Base, Req, Opts) ->
    settle(Base, Req, Opts).

bundle_complete(Base, Req, Opts) ->
    settle(Base, Req, Opts).

settle(Base, Req, Opts) ->
    Size = hb_util:int(hb_maps:get(<<"bundled-size">>, Req, 0, Opts)),
    case quote(Base, Size, Opts) of
        {ok, 0} ->
            {ok, Req};
        {ok, Amount} ->
            charge(Base, Req, Amount, Opts);
        Error ->
            Error
    end.

quote(Base, Size, Opts) ->
    PricingDevice =
        hb_maps:get(
            <<"pricing-device">>,
            Base,
            <<"arweave-byte-pricing@1.0">>,
            Opts
        ),
    hb_ao:resolve(
        Base#{ <<"device">> => PricingDevice },
        #{
            <<"path">> => <<"quote">>,
            <<"resource">> => <<"arweave-bytes">>,
            <<"amount">> => Size
        },
        Opts
    ).

charge(Base, Req, Amount, Opts) ->
    Account = account(Base, Opts),
    Recipient = recipient(Base, Opts),
    LedgerDevice =
        hb_maps:get(
            <<"ledger-device">>,
            Base,
            <<"process-ledger@1.0">>,
            Opts
        ),
    ChargeReq =
        hb_message:commit(
            #{
                <<"path">> => <<"charge">>,
                <<"quantity">> => Amount,
                <<"account">> => Account,
                <<"recipient">> => Recipient,
                <<"request">> => Req
            },
            Opts
        ),
    case hb_ao:resolve(Base#{ <<"device">> => LedgerDevice }, ChargeReq, Opts) of
        {ok, _} -> {ok, Req};
        Error -> Error
    end.

account(Base, Opts) ->
    normalize_account(
        hb_maps:get(
            <<"settlement-account">>,
            Base,
            hb_opts:get(p4_recipient, hb_opts:get(operator, undefined, Opts), Opts),
            Opts
        )
    ).

recipient(Base, Opts) ->
    normalize_account(
        hb_maps:get(
            <<"beneficiary">>,
            Base,
            hb_opts:get(bundler_beneficiary, hb_opts:get(operator, undefined, Opts), Opts),
            Opts
        )
    ).

normalize_account(Account) when ?IS_ID(Account) ->
    hb_util:human_id(Account);
normalize_account(Account) ->
    Account.
