-module(dev_ruby).
-implements(<<"ruby@mruby-3.3a">>).
%%
%% HyperBEAM device for Ruby modules executed via embedded MRuby.
%%
%% Uses an MRuby engine running in a native port worker process,
%% communicating via 4-byte length-prefixed ETF over stdio.
%% Each device instance gets its own isolated MRuby VM.
%%
%% Protocol:
%%   - Device modules are Ruby scripts (content-type: application/ruby)
%%   - Functions are singleton methods on AOProcess
%%   - AO host operations (resolve, get, set, event) are handled via
%%     the host_call protocol between C binary and Erlang
%%
%% Follows the same interface as dev_lua.erl:
%%   info/1, init/3, snapshot/3, normalize/3, functions/3
%%   compute/4 (internal), call_function/4 (internal)
%%

-export([info/1, init/3, snapshot/3, normalize/3, functions/3]).

-include("include/hb.hrl").
-include_lib("eunit/include/eunit.hrl").

%% Ruby content-type check.
-define(IS_RUBY_TYPE(CT), CT == <<"application/ruby">> orelse CT == <<"text/x-ruby">>).

%% Default sandbox definitions (disable dangerous Ruby functions)
-define(DEFAULT_SANDBOX, [
    {['AOProcess', 'send'], <<"sandboxed">>},
    {['AOProcess', 'eval'], <<"sandboxed">>},
    {['AOProcess', 'load'], <<"sandboxed">>}
]).

%% ========================================================================
%%  Public API
%% ========================================================================

%% @doc Device info - returns the default compute function and excluded keys.
info(Base) ->
    #{
	default => fun compute/4,
	excludes =>
	    [
		<<"id">>,
		<<"commitments">>,
		<<"committers">>,
		<<"keys">>,
		<<"path">>,
		<<"set">>,
		<<"remove">>,
		<<"verify">>,
		<<"encode">>,
		<<"decode">>
	    ] ++
	    maps:keys(Base)
    }.

%% @doc Initialize the device state.
init(Base, Req, Opts) ->
    ensure_initialized(Base, Req, Opts).

%% @doc Snapshot the device state.
snapshot(Base, _Req, Opts) ->
    case hb_private:get(<<"port">>, Base, Opts) of
	not_found ->
	    {error, <<"Cannot snapshot Ruby device: not initialized.">>};
	_Port ->
	    %% Snapshot: capture the loaded modules
	    Modules = hb_private:get(<<"modules">>, Base, Opts),
	    case Modules of
		not_found ->
		    {error, <<"No modules loaded.">>};
		ModList when is_list(ModList) ->
		    Snapshot = term_to_binary(ModList),
		    {ok, #{ <<"body">> => Snapshot }}
	    end
    end.

%% @doc Normalize a base message, restoring from snapshot if available.
normalize(Base, _Req, RawOpts) ->
    Opts = RawOpts#{ <<"hashpath">> => ignore },
    case hb_private:get(<<"modules">>, Base, Opts) of
	not_found ->
	    DeviceKey =
		case hb_ao:get(<<"device-key">>, {as, <<"message@1.0">>, Base}, Opts) of
		    not_found -> [];
		    Key -> [Key]
		end,
	    SnapshotBin =
		hb_ao:get(
		    [<<"snapshot">>] ++ DeviceKey ++ [<<"body">>],
		    {as, dev_message, Base},
		    Opts
		),
	    case SnapshotBin of
		not_found ->
		    {ok, Base};
		_ ->
		    try
			Modules = binary_to_term(SnapshotBin),
			{ok, hb_private:set(Base, <<"modules">>, Modules, Opts)}
		    catch
			_:_ -> {ok, Base}
		    end
	    end;
	_ ->
	    {ok, Base}
    end.

%% @doc Return a list of all functions in the Ruby environment.
functions(Base, _Req, Opts) ->
    case hb_private:get(<<"port">>, Base, Opts) of
	not_found ->
	    {error, not_found};
	Port ->
	    case dev_ruby_mruby:functions(Port) of
		{functions, Funs} when is_list(Funs) ->
		    {ok, Funs};
		{error, Reason} ->
		    {error, Reason}
	    end
    end.

%% ========================================================================
%%  Internal: Initialization
%% ========================================================================

%% @doc Ensure the MRuby VM is initialized.
ensure_initialized(Base, _Req, Opts) ->
    case hb_private:from_message(Base) of
	#{<<"port">> := _} ->
	    ?event(debug_ruby, ruby_port_already_initialized),
	    {ok, Base};
	#{<<"modules">> := Modules} when is_list(Modules) ->
	    ?event(debug_ruby, initializing_ruby_port_from_snapshot),
	    initialize(Base, Modules, Opts);
	_ ->
	    ?event(debug_ruby, initializing_ruby_port),
	    case find_modules(Base, Opts) of
		{ok, Modules} ->
		    initialize(Base, Modules, Opts);
		Error ->
		    Error
	    end
    end.

%% @doc Find Ruby modules in the base message.
find_modules(Base, Opts) ->
    MaybeBodyMod =
	case hb_ao:get(<<"content-type">>, {as, <<"message@1.0">>, Base}, Opts) of
	    CT when ?IS_RUBY_TYPE(CT) -> [Base];
	    _ -> []
	end,
    ?event(debug_ruby, {finding_modules, {base, Base}, {body_mod, MaybeBodyMod}}),
    case {hb_ao:get(<<"module">>, {as, <<"message@1.0">>, Base}, Opts), MaybeBodyMod} of
	{not_found, []} ->
	    {error, <<"No Ruby modules found when preparing environment for call.">>};
	{not_found, _} ->
	    load_modules(MaybeBodyMod, Opts);
	{Module, _} when is_binary(Module) ->
	    find_modules(Base#{<<"module">> => [Module]}, Opts);
	{Module, _} when is_map(Module) ->
	    case hb_ao:get(<<"content-type">>, Module, Opts) of
		RubyCT when ?IS_RUBY_TYPE(RubyCT) ->
		    find_modules(Base#{<<"module">> => [Module]}, Opts);
		_ ->
		    find_modules(Base#{<<"module">> => maps:values(Module)}, Opts)
	    end;
	{Modules, _} when is_list(Modules) ->
	    load_modules(MaybeBodyMod ++ Modules, Opts)
    end.

%% @doc Load a list of Ruby modules.
load_modules(Modules, Opts) -> load_modules(Modules, Opts, []).

load_modules([], _Opts, Acc) ->
    {ok, lists:reverse(Acc)};

load_modules([ModuleID | Rest], Opts, Acc) when is_binary(ModuleID) ->
    case hb_cache:read(ModuleID, Opts) of
	{ok, Module} when is_binary(Module) ->
	    load_modules(Rest, Opts, [{ModuleID, Module} | Acc]);
	{ok, ModuleMsg} when is_map(ModuleMsg) ->
	    load_modules([ModuleMsg | Rest], Opts, Acc);
	not_found ->
	    {error, #{
		<<"status">> => 404,
		<<"body">> => <<"Ruby module '", ModuleID/binary, "' not found.">>
	    }}
    end;

load_modules([Module | Rest], Opts, Acc) when is_map(Module) ->
    ModuleBin = hb_ao:get_first(
	[{Module, <<"body">>}, {Module, <<"data">>}], Module, Opts),
    case ModuleBin of
	not_found ->
	    {error, #{
		<<"status">> => 404,
		<<"body">> => <<"Ruby module not loadable. Must have a `body' element.">>,
		<<"module">> => Module
	    }};
	ModuleBin ->
	    ModuleRef =
		case hb_maps:find(<<"name">>, Module, Opts) of
		    {ok, Name} -> Name;
		    error -> hb_message:id(Module, all, Opts)
		end,
	    load_modules(Rest, Opts, [{ModuleRef, ModuleBin} | Acc])
    end.

%% @doc Initialize the MRuby port with the given modules.
initialize(Base, Modules, Opts) ->
    %% Get the path to the hb_mruby binary
    PrivBin = dev_ruby_mruby:priv_path(),
    ?event(debug_ruby, {starting_port, {bin, PrivBin}, {modules, length(Modules)}}),

    %% Extract only the Ruby source binaries for the C binary.
    %% Modules is [{ModuleRef, ModuleBin}, ...] - C init expects
    %% a flat list of strings (module source code), not tuples.
    ModuleSources = [Src || {_, Src} <- Modules, is_binary(Src)],
    ?event(debug_ruby, {module_sources, length(ModuleSources)}),

    %% Start the port (this also sends the init command)
    case dev_ruby_mruby:start_link(PrivBin, ModuleSources) of
	{ok, Port} ->
	    ?event(debug_ruby, {ruby_port_started, Port}),
	    %% Store port and modules in private state
   Base1 = hb_private:set(Base, <<"port">>, Port, Opts),
    Base2 = hb_private:set(Base1, <<"modules">>, Modules, Opts),
	    {ok, Base2};
	{error, Reason} ->
	    ?event(error, {ruby_port_failed, Reason}),
	    {error, #{
		<<"status">> => 500,
		<<"body">> => iolist_to_binary([
		    <<"Failed to start MRuby worker: ">>,
		    iolist_to_binary(Reason)
		])
	    }}
    end.

%% ========================================================================
%%  Internal: Computation
%% ========================================================================

%% @doc Default compute function - calls the requested Ruby function.
%% Matches the dev_lua compute/4 signature: compute(Key, RawBase, RawReq, Opts)
compute(Key, RawBase, RawReq, Opts) ->
    ?event(debug_ruby, compute_called),
    Req = hb_cache:read_all_commitments(RawReq, Opts),
    case ensure_initialized(RawBase, Req, Opts) of
	{ok, Base} ->
	    do_compute(Key, Base, Req, Opts);
	Error ->
	    Error
    end.

%% @doc Execute the Ruby function call.
do_compute(Key, Base, Req, Opts) ->
    %% Get the function name from the request
    FunctionRaw =
	hb_ao:get_first(
	    [
		{Req, <<"body/function">>},
		{Req, <<"function">>},
		{{as, <<"message@1.0">>, Base}, <<"function">>}
	    ],
	    Key,
	    Opts#{<<"hashpath">> => ignore}
	),
    %% Normalize Function to a binary - accept atom, binary, or list.
    %% Reject not_found and other invalid shapes.
    Function = case FunctionRaw of
        A when is_atom(A), A =/= not_found ->
            atom_to_binary(A, utf8);
        B when is_binary(B) ->
            B;
        L when is_list(L) ->
            list_to_binary(L);
        not_found ->
            {error, #{
                <<"status">> => 400,
                <<"body">> => <<"No function specified. Provide via path key or request body.">>
            }};
        _ ->
            ?event(error, {invalid_function_type, {raw, FunctionRaw}}),
            {error, #{
                <<"status">> => 400,
                <<"body">> => iolist_to_binary(["Invalid function type: ", io_lib:format("~p", [FunctionRaw])])
            }}
    end,
    case Function of
        {error, _} = Err -> Err;
        _ -> do_compute_call(Function, Base, Req, Opts)
    end.

do_compute_call(Function, Base, Req, Opts) ->
    ?event(debug_ruby, {function_found, Function}),

    %% Get parameters (process state, message, opts)
    Params =
	hb_ao:get_first(
	    [
		{Req, <<"body/parameters">>},
		{Req, <<"parameters">>},
		{{as, <<"message@1.0">>, Base}, <<"parameters">>}
	    ],
	    [hb_private:reset(Base), Req, #{}],
	    Opts#{<<"hashpath">> => ignore}
	),
    ?event(debug_ruby, {parameters_found, Params}),

    %% Resolve all hyperstate links
    ResolvedParams = hb_cache:ensure_all_loaded(Params, Opts),

    %% Get the port from private state (set by init)
    Private = hb_private:from_message(Base),
    ?event(debug_ruby, {private_state, Private}),
    #{<<"port">> := Port} = Private,

    %% Build the call payload for the C binary:
    %% #{function => Function, args => [Process, Message, Opts]}
    CallPayload = #{
	<<"function">> => Function,
	<<"args">> => build_call_args(ResolvedParams, Base, Opts)
    },

    ?event(debug_ruby, {call_payload, {function, Function, fun_type, is_binary(Function)}, payload, CallPayload}),

    ?event(ruby, {calling_ruby_func,
	    {function, Function},
	    {args, CallPayload}
    }),

    %% Call the function via the port
    case dev_ruby_mruby:call(Port, CallPayload) of
	{result, Result} ->
	    ?event(ruby, {result, {function, Function}, {result, Result}}),
	    process_response(Result, Function, Base, Opts);
{error, Reason} ->
    ?event(error, {ruby_call_failed, {function, Function}, {reason, Reason}}),
    ErrorBody = case Reason of
        #{<<"message">> := Msg, <<"class">> := Cls} ->
            iolist_to_binary([binary_to_list(Cls), ": ", binary_to_list(Msg)]);
        #{<<"message">> := Msg} ->
            binary_to_list(Msg);
        _ ->
            iolist_to_binary(io_lib:format("~p", [Reason]))
    end,
    {error, #{
        <<"status">> => 500,
        <<"body">> => iolist_to_binary(["Ruby call failed: ", ErrorBody])
    }}
    end.

%% @doc Build the 3-argument call args for AOProcess.<func>(process, message, opts).
build_call_args(Params, _Base, _Opts) when is_list(Params) ->
    %% Params is already the [Process, Message, Opts] stack args.
    Params;
build_call_args(Params, Base, _Opts) when is_map(Params) ->
    %% Process: the current process state from params
    Process = maps:get(<<"process">>, Params, hb_private:reset(Base)),
    %% Message: the input/message from params
    Message = maps:get(<<"message">>, Params, Params),
    %% Opts: execution options as a map
    OptsMap = maps:get(<<"opts">>, Params, #{}),
    [Process, Message, OptsMap];
build_call_args(Params, Base, _Opts) ->
    %% Scalar param - wrap as single arg
    [Params, Base, #{}].

%% @doc Process the response from the Ruby VM.
process_response(#{status := ok, value := Value}, Function, Base, Opts) ->
    process_value(Value, Function, Base, Opts);
process_response(#{<<"status">> := ok, <<"value">> := Value}, Function, Base, Opts) ->
    process_value(Value, Function, Base, Opts);
process_response(#{status := Status} = Result, _Function, _Base, _Opts) ->
    {hb_util:atom(Status), Result};
process_response(#{<<"status">> := Status} = Result, _Function, _Base, _Opts) ->
    {hb_util:atom(Status), Result};
process_response(Result, Function, Base, Opts) ->
    process_value(Result, Function, Base, Opts).

process_value(Value, _Function, Base, _Opts) when is_map(Value) ->
    {ok, hb_private:set_priv(Value, hb_private:from_message(Base))};
process_value(Value, Function, Base, _Opts) ->
    {ok, hb_private:set_priv(#{Function => Value}, hb_private:from_message(Base))}.

%% ========================================================================
%%  Helpers
%% ========================================================================
