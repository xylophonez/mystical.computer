%%% @doc Route requests to different P4 pricing devices.
%%%
%%% This is a small pricing-device adapter. It allows a node to keep static
%%% route prices on `simple-pay@1.0' while sending specific routes to another
%%% narrow pricing device.
-module(dev_pricing_router).
-export([info/1, estimate/3, price/3]).

-include("include/hb.hrl").

info(_) ->
    #{ exports => [<<"estimate">>, <<"price">>] }.

estimate(Base, Req, Opts) ->
    forward(<<"estimate">>, Base, Req, Opts).

price(Base, Req, Opts) ->
    forward(<<"price">>, Base, Req, Opts).

forward(Path, Base, Req, Opts) ->
    PricingMsg = pricing_msg(Base, Req#{ <<"path">> => Path }, Opts),
    hb_ao:resolve(PricingMsg, Req#{ <<"path">> => Path }, Opts).

pricing_msg(Base, Req, Opts) ->
    Route = selected_route(Base, Req, Opts),
    Device =
        hb_maps:get(
            <<"pricing-device">>,
            Route,
            hb_maps:get(<<"default-pricing-device">>, Base, <<"simple-pay@1.0">>, Opts),
            Opts
        ),
    (maps:merge(Base, maps:remove(<<"template">>, Route)))#{
        <<"device">> => Device
    }.

selected_route(Base, Req, Opts) ->
    Request = hb_ao:get(<<"request">>, Req, #{}, Opts#{ <<"hashpath">> => ignore }),
    Routes =
        hb_maps:get(
            <<"pricing-routes">>,
            Base,
            hb_opts:get(<<"pricing-routes">>, [], Opts),
            Opts
        ),
    case dev_router:match(#{ <<"routes">> => Routes }, Request, Opts) of
        {ok, Route} -> Route;
        _ -> #{}
    end.
