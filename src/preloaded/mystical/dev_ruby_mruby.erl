-module(dev_ruby_mruby).
%%
%% MRuby port wrapper for HyperBEAM Ruby device.
%%
%% Wraps the hb_mruby C binary as an Erlang port. Communicates via
%% 4-byte length-prefixed Erlang External Term Format (ETF) over stdio.
%%
%% Host call protocol (synchronous):
%%   C -> Erlang: {host_call, Ref, Module, Function, Args}
%%   Erlang -> C: {host_return, Ref, Result}
%%
%% Usage from dev_ruby.erl:
%%   {ok, Pid} = dev_ruby_mruby:start_link(PrivBin, Modules).
%%   {result, Res} = dev_ruby_mruby:call(Pid, #{
%%       <<"function">> => <<"hello">>,
%%       <<"args">> => [#{}, #{<<"name">> => <<"Alice">>}, #{}]
%%   }).
%%   {ok, Funs} = dev_ruby_mruby:functions(Pid).
%%   dev_ruby_mruby:stop(Pid).
%%

-behaviour(gen_server).

-export([start_link/2, priv_path/0]).
-export([call/2, functions/1, stop/1]).
-export([init/1, handle_call/3,
	 handle_cast/2, handle_info/2,
	 terminate/2]).

-include("include/hb.hrl").

-define(TIMEOUT, 5000).

%% ========================================================================
%%  Public API
%% ========================================================================

%% @doc Start the MRuby port wrapper. Opens the port, sends init with
%% the given Ruby modules, and waits for the init response.
start_link(PrivBin, Modules) ->
    gen_server:start_link(?MODULE, {PrivBin, Modules}, []).

%% @doc Return the path to the hb_mruby binary in the priv directory.
priv_path() ->
    filename:join(
        [hb_device_archive:implementation_dir(?MODULE), "bin", "hb_mruby"]
    ).

%% @doc Send a call command to the port and wait for the result.
call(Pid, Payload) ->
    gen_server:call(Pid, {call, Payload}, ?TIMEOUT).

%% @doc Query the list of available functions from the port.
functions(Pid) ->
    gen_server:call(Pid, functions, ?TIMEOUT).

%% @doc Stop the port gracefully.
stop(Pid) ->
    gen_server:call(Pid, stop, ?TIMEOUT).

%% ========================================================================
%%  gen_server callbacks
%% ========================================================================

init({PrivBin, Modules}) ->
    process_flag(trap_exit, true),
    %% Open port in raw binary mode - manual length framing
    Port = open_port({spawn_executable, PrivBin}, [
	    eof, binary, exit_status
    ]),
    port_connect(Port, self()),
    %% Send init command and wait for response
    send(Port, {init, #{<<"modules">> => Modules}}),
    ?event(debug_ruby, {init_sent, {modules_count, length(Modules)}, {first_module_size, case Modules of [H|_] when is_binary(H) -> byte_size(H); _ -> no_binary end}}),
    receive
	{Port, {data, Data}} ->
	    case decode(Data) of
		{ok, _} ->
		    ?event(debug_ruby, {port_initialized, {pid, self()}}),
		    {ok, #{port => Port}};
		Error ->
		    ?event(error, {port_init_failed, Error}),
		    {stop, {port_init_failed, Error}}
	    end;
	{Port, {exit_status, Code}} ->
	    {stop, {port_exited_during_init, Code}}
    after ?TIMEOUT ->
	    {stop, timeout_waiting_for_port_init}
    end.

handle_call({call, Payload}, _From, #{port := Port} = State) ->
    Function = maps:get(<<"function">>, Payload, undefined),
    ?event(debug_ruby, {call_to_port, {function, Function}, {payload_keys, maps:keys(Payload)}}),
    send(Port, {call, Payload}),
    {reply, wait_response(Port), State};

handle_call(functions, _From, #{port := Port} = State) ->
    send(Port, {functions, #{}}),
    {reply, wait_response(Port), State};

handle_call(stop, _From, #{port := Port} = State) ->
    %% Send stop command to C binary, let it exit gracefully
    send(Port, {stop, #{}}),
    {stop, normal, ok, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({Port, {data, Data}}, #{port := Port} = State) ->
    Term = decode(Data),
    case Term of
	%% Host call from C binary - route to dev_ruby_lib synchronously
	{host_call, Ref, Fun, Args} when is_integer(Ref) ->
	    Result = dev_ruby_lib:call(atom_to_list(Fun), Args),
	    send(Port, {host_return, Ref, Result}),
	    {noreply, State};
	%% Unexpected data (shouldn't happen without pending call)
	_ ->
	    ?event(debug_ruby, {unexpected_port_data, Term}),
	    {noreply, State}
    end;

handle_info({Port, eof}, #{port := Port} = State) ->
    {stop, normal, State};

handle_info({Port, {exit_status, Code}}, #{port := Port} = State)
  when Code =/= 0 ->
    ?event(error, {port_exited, {code, Code}}),
    {stop, {port_exited, Code}, State};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #{port := Port}) when is_port(Port) ->
    case port_connect(Port, self()) of
	true ->
	    receive after 0 -> ok end,
	    port_close(Port);
	false -> ok
    end;
terminate(_Reason, _State) ->
    ok.

%% ========================================================================
%%  Internal: Port communication
%% ========================================================================

%% @doc Send an ETF-encoded term to the port with 4-byte length prefix.
send(Port, Term) ->
    Bin = term_to_binary(Term),
    Len = byte_size(Bin),
    port_command(Port, <<Len:32/big, Bin/binary>>).

%% @doc Decode an ETF term from port data (with 4-byte length prefix).
decode(Data) ->
    case Data of
	<<Len:32/big, 131:8, Rest/binary>> ->
	    TermSize = Len - 1,
	    case byte_size(Rest) of
		BS when BS >= TermSize ->
		    <<TermBin:TermSize/binary, _Tail/binary>> = Rest,
		    try binary_to_term(<<131:8, TermBin/binary>>) of
			Term -> Term
		    catch
			error:_ -> {error, decode_failed}
		    end;
		_ ->
		    {error, {incomplete_frame, Len}}
	    end;
	_ ->
	    {error, {bad_frame, Data}}
    end.
%% @doc Send a host return to the port.
host_return(Port, Ref, Result) ->
    send(Port, {host_return, Ref, Result}).

%% @doc Wait for a response from the port, handling any host_call round-trips.
%% The C binary may emit host_call messages during a call - we handle them
%% inline and continue waiting for the final response.
%%
%% Note: C binary sends {host_call, Ref, FunctionName, Args} (4 elements)
%% where FunctionName is the AO host function name (resolve, get, set, event, etc.).
wait_response(Port) ->
    receive
	{Port, {data, Data}} ->
	    Term = decode(Data),
	    case Term of
		%% Host call from C binary - handle and continue waiting
		{host_call, Ref, Fun, Args} when is_integer(Ref) ->
		    Result = dev_ruby_lib:call(atom_to_list(Fun), Args),
		    send(Port, {host_return, Ref, Result}),
		    wait_response(Port);
		%% Final response
		_ ->
		    Term
	    end;
	{Port, {exit_status, Code}} when Code =/= 0 ->
	    {error, {port_exited, Code}};
	{Port, eof} ->
	    {error, port_closed}
    after ?TIMEOUT ->
	    {error, timeout}
    end.
