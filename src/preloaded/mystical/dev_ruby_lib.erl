-module(dev_ruby_lib).
%%
%% Erlang-side AO host functions for the Ruby device.
%%
%% Called from hb_mruby.erl when the MRuby VM emits host_call requests.
%% These implement the AO host operations that Ruby code invokes through
%% the AO module stubs (AO.resolve, AO.get, AO.set, AO.event, etc.).
%%
%% The C binary sends: {host_call, Ref, Module, Function, Args}
%% This module returns: Result (any Erlang term, encoded back as ETF)
%%

-export([call/2, resolve/1, get/2, set/3, event/2]).

-include("include/hb.hrl").

%% ========================================================================
%%  Dispatcher
%% ========================================================================

%% @doc Dispatch a host call to the appropriate handler.
%% The C binary sends {host_call, Ref, FunctionName, Args} where FunctionName
%% is the AO host function name (resolve, get, set, event, etc.).
%% Args is a list of ETF-decoded terms.
call(Fun, Args) ->
    case {Fun, Args} of
	%% AO.resolve(tag) -> ProcessInfo
	{"resolve", [Tag]} ->
	    resolve(Tag);
	%% AO.get(process, key) -> Value
	{"get", [Process, Key]} ->
	    get(Process, Key);
	%% AO.set(process, key, value) -> NewProcess
	{"set", [Process, Key, Value]} ->
	    set(Process, Key, Value);
	%% AO.event(name, data) -> ok
	{"event", [Name, Data]} ->
	    event(Name, Data);
	%% AO.event(name) -> ok
	{"event", [Name]} ->
	    event(Name, #{});
	%% AO.process_id() -> Binary ID
	{"process_id", []} ->
	    metadata(<<"PROCESS_ID">>);
	%% AO.timestamp() -> Timestamp string
	{"timestamp", []} ->
	    metadata(<<"TIMESTAMP">>);
	%% AO.block_height() -> Block height as integer
	{"block_height", []} ->
	    case metadata(<<"BLOCK_HEIGHT">>) of
		<<>> -> 0;
		BH -> list_to_integer(binary_to_list(BH))
	    end;
	%% AO.cu_id() -> CU ID
	{"cu_id", []} ->
	    metadata(<<"CU_ID">>);
	%% AO.mux_id() -> Muxer ID
	{"mux_id", []} ->
	    metadata(<<"MUX_ID">>);
	%% AO.input_id() -> Input ID
	{"input_id", []} ->
	    metadata(<<"INPUT_ID">>);
	%% AO.target() -> Target
	{"target", []} ->
	    metadata(<<"TARGET">>);
	%% AO.module_id() -> Module ID
	{"module_id", []} ->
	    metadata(<<"MODULE_ID">>);
	%% Unknown call
	_ ->
	    {error, list_to_binary(["Unknown AO host call: ", Fun])}
    end.

%% ========================================================================
%%  AO.host.resolve(tag)
%% ========================================================================

%% @doc Resolve a process tag to process information.
resolve(Tag) ->
    ?event(ruby_host, {resolve, Tag}),
    %% In a full implementation, this would query the process registry
    %% via hb_ao:resolve/2 or similar. For now, return a basic structure.
    TagBin = to_binary(Tag),
    {ok, #{
	<<"address">> => TagBin,
	<<"tags">> => #{}
    }}.

%% ========================================================================
%%  AO.host.get(process, key)
%% ========================================================================

%% @doc Get a value from the process map by key.
get(Process, Key) ->
    KeyBin = to_binary(Key),
    case maps:find(KeyBin, Process) of
	{ok, Value} -> {ok, Value};
	error -> {ok, undefined}
    end.

%% ========================================================================
%%  AO.host.set(process, key, value)
%% ========================================================================

%% @doc Set a value in the process map.
set(Process, Key, Value) ->
    KeyBin = to_binary(Key),
    {ok, Process#{KeyBin => Value}}.

%% ========================================================================
%%  AO.host.event(name, data)
%% ========================================================================

%% @doc Emit an event via the HyperBEAM event system.
event(Name, Data) ->
    NameBin = to_binary(Name),
    ?event(ruby_event, #{event => NameBin, data => Data}),
    ?event(global, {ruby_event, NameBin, Data}),
    {ok, <<"ok">>}.

%% ========================================================================
%%  Metadata helpers
%% ========================================================================

metadata(Key) ->
    %% Read from process dictionary set by dev_ruby during init.
    %% The device sets these from the AO execution context.
    case get(Key) of
	undefined -> <<>>;
	Val -> Val
    end.

%% ========================================================================
%%  Utilities
%% ========================================================================

to_binary(B) when is_binary(B) -> B;
to_binary(A) when is_atom(A) -> atom_to_binary(A, latin1);
to_binary(S) when is_list(S) -> list_to_binary(S).