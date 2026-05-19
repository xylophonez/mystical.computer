#!/usr/bin/env escript
%% -*- erlang -*-
main(_) ->
    {ok, Cwd} = file:get_cwd(),
    OutDir = filename:join([Cwd, "_build/mruby-integration-test"]),
    Ebin = filename:join([Cwd, "_build/default/lib/hb/ebin"]),
    Core = filename:join([Cwd, "src/core"]),
    Mystical = filename:join([Cwd, "src/preloaded/mystical"]),
    PrivBin = filename:join([Cwd, "native/hb_mruby/hb_mruby"]),

    ok = filelib:ensure_dir(filename:join([OutDir, "dummy.beam"])),
    code:add_patha(Ebin),
    {ok, dev_ruby_lib} =
        compile:file(
            filename:join([Mystical, "dev_ruby_lib.erl"]),
            [{i, Core}, {outdir, OutDir}]
        ),
    {ok, dev_ruby_mruby} =
        compile:file(
            filename:join([Mystical, "dev_ruby_mruby.erl"]),
            [{i, Core}, {outdir, OutDir}]
        ),
    code:add_patha(OutDir),
    code:load_file(dev_ruby_mruby),
    code:load_file(dev_ruby_lib),

    io:format("=== MRuby Integration Tests ===~n~n", []),

    NL = 10,
    RubyCode = list_to_binary([
        "module AOProcess", [NL],
        "  def self.hello(process, message, opts)", [NL],
        "    name = opts[\"name\"] || \"World\"", [NL],
        "    \"Hello from Ruby, \" + name + \"!\"", [NL],
        "  end", [NL],
        "  def self.add(process, message, opts)", [NL],
        "    a = opts[\"a\"] || 0", [NL],
        "    b = opts[\"b\"] || 0", [NL],
        "    a + b", [NL],
        "  end", [NL],
        "  def self.error_test(process, message, opts)", [NL],
        "    raise \"boom\"", [NL],
        "  end", [NL],
        "end", [NL]
    ]),
    HostCode = list_to_binary([
        "module AO", [NL],
        "  def self.get(process, key)", [NL],
        "    \"value_for_\" + key", [NL],
        "  end", [NL],
        "end", [NL],
        "module AOProcess", [NL],
        "  def self.test_host_call(process, message, opts)", [NL],
        "    AO.get(process, \"test_key\")", [NL],
        "  end", [NL],
        "end", [NL]
    ]),

    %% 1. Init
    {ok, Pid1} = dev_ruby_mruby:start_link(PrivBin, [RubyCode]),
    io:format("1. Init:                 PASS~n"),

    %% 2. Call hello (default)
    {result, #{status := ok, value := R1}} = dev_ruby_mruby:call(Pid1, #{
        <<"function">> => <<"hello">>,
        <<"args">> => [#{}, #{}, #{}]
    }),
    assert_eq(<<"Hello from Ruby, World!">>, R1, "hello default"),
    io:format("2. hello(default):       PASS (~s)~n", [R1]),

    %% 3. Call hello (with opts)
    {result, #{status := ok, value := R2}} = dev_ruby_mruby:call(Pid1, #{
        <<"function">> => <<"hello">>,
        <<"args">> => [#{}, #{}, #{<<"name">> => <<"Alice">>}]
    }),
    assert_eq(<<"Hello from Ruby, Alice!">>, R2, "hello opts"),
    io:format("3. hello(opts):          PASS (~s)~n", [R2]),

    %% 4. Call add
    {result, #{status := ok, value := R3}} = dev_ruby_mruby:call(Pid1, #{
        <<"function">> => <<"add">>,
        <<"args">> => [#{}, #{}, #{<<"a">> => 3, <<"b">> => 4}]
    }),
    assert_eq(7, R3, "add"),
    io:format("4. add(3,4):             PASS (~p)~n", [R3]),

    %% 5. Functions query
    {functions, Funs} = dev_ruby_mruby:functions(Pid1),
    true = lists:member(hello, Funs) orelse lists:member(<<"hello">>, Funs),
    io:format("5. functions query:      PASS (~p)~n", [Funs]),

    %% 6. Error handling
    {error, #{class := ErrClass, message := ErrMsg}} = dev_ruby_mruby:call(Pid1, #{
        <<"function">> => <<"error_test">>,
        <<"args">> => [#{}, #{}, #{}]
    }),
    io:format("6. error handling:       PASS (~s: ~s)~n", [ErrClass, ErrMsg]),

    %% 7. Stop
    ok = dev_ruby_mruby:stop(Pid1),
    io:format("7. stop:                 PASS~n"),

    %% 8. Host call (Ruby-side AO module, no Erlang round-trip needed)
    {ok, Pid2} = dev_ruby_mruby:start_link(PrivBin, [HostCode]),
    {result, #{status := ok, value := R4}} = dev_ruby_mruby:call(Pid2, #{
        <<"function">> => <<"test_host_call">>,
        <<"args">> => [#{<<"id">> => <<"test">>}, #{}]
    }),
    assert_eq(<<"value_for_test_key">>, R4, "host_call"),
    io:format("8. host_call (Ruby AO):  PASS (~s)~n", [R4]),
    ok = dev_ruby_mruby:stop(Pid2),

    io:format("~n=== All 8 tests passed ===~n"),
    halt(0).

assert_eq(Expected, Expected, _Label) -> ok;
assert_eq(Expected, Actual, Label) ->
    io:format("FAIL: ~s expected ~p got ~p~n", [Label, Expected, Actual]),
    halt(1).
