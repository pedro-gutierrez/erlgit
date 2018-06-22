-module(git_sh).
-export([sh/1,   sh/2,   sh/3,
         exec/2, exec/3,

         run/2,
         stop/1, join/1,
         stop_all/0,
         kill/1,
         expect/2,
         expect/3,
         send/2,

         params/1]).

-record(sh, {pid, port, opts}).
-define(FMT(Str, Args), lists:flatten(io_lib:format(Str, Args))).

%%
%% Options = [Option] -- defaults to [use_stdout, abort_on_error]
%% Option = ErrorOption | OutputOption | {cd, string()} | {env, Env}
%% ErrorOption = return_on_error | abort_on_error | {abort_on_error, string()}
%% OutputOption = use_stdout | {use_stdout, bool()}
%% Env = [{string(), Val}]
%% Val = string() | false
%%
sh(Command0) ->
    sh(Command0, []).
sh(Command0, Options0) ->
    DefaultOptions = [use_stdout, abort_on_error],
    Options = [expand_sh_flag(V)
               || V <- proplists:compact(Options0 ++ DefaultOptions)],

    ErrorHandler = proplists:get_value(error_handler, Options),
    OutputHandler = proplists:get_value(output_handler, Options),

    Command = patch_on_windows(Command0, proplists:get_value(env, Options, [])),
    PortSettings = proplists:get_all_values(port_settings, Options) ++
        [exit_status, {line, 16384}, use_stdio, stderr_to_stdout, hide],
    Port = open_port({spawn, binary_to_list(iolist_to_binary(Command))}, PortSettings),

    case sh_loop(Port, OutputHandler, []) of
        {ok, _Output} = Ok ->
            Ok;
        {error, {_Rc, _Output}=Err} ->
            ErrorHandler(Command, Err)
    end.

sh(Command, Args, Options) ->
    sh(?FMT(Command, Args), Options).

exec(Command, Env) ->
    exec(Command, Env, element(2, file:get_cwd())).

exec(Command, Env, Dir) ->
    Port = open_port({spawn, Command}, [{cd, Dir}, {env, Env}, exit_status, {line, 16384},
                                        use_stdio, stderr_to_stdout]),
    sh_loop(Port).




run(Cmd, Opts) ->
    Dir = proplists:get_value(cd, Opts, element(2, file:get_cwd())),
    Env = proplists:get_value(env, Opts, []),

    %% Try to be smart about the provided command. If it's got any && or ; in it,
    %% it's a multi-statement bit of shell, so there's no good way for use to track
    %% the PID.
    case re:run(Cmd, "(&&|;)") of
        nomatch ->
            ActualCmd = ?FMT("/usr/bin/env sh -c \"echo $$; exec ~s\"", [Cmd]);
        _ ->
            ActualCmd = Cmd,
            case proplists:get_bool(async, Opts) of
                true ->
                    error({options,
                           ?FMT("Async option not allowed with sh:run/2 when command"
                                " contains '&&' or ';': ~s\n", [Cmd])});
                false ->
                    ok
            end
    end,

    Port = open_port({spawn, ActualCmd}, [{cd, Dir}, {env, Env},
                                          exit_status, {line, 16384},
                                          use_stdio, stderr_to_stdout]),
    case proplists:get_bool(async, Opts) of
        true ->
            Pid = read_pid(Port),
            Ref = make_ref(),
            erlang:put(Ref, #sh{ pid = Pid, port = Port, opts = Opts}),
            Ref;
        false ->
            acc_loop(Port, [])
    end.

kill(Ref) ->
    #sh { pid = Pid } = erlang:get(Ref),
    _ = os:cmd(?FMT("kill -9 ~s", [Pid])),
    ok.

stop(Ref) ->
    #sh { pid = Pid, port = Port } = erlang:get(Ref),
    _ = os:cmd(?FMT("kill ~s", [Pid])),
    exit_loop(Port).

join(Ref) ->
    #sh { pid = _Pid, port = Port } = erlang:get(Ref),
    %% erlang:port_close(Port),
    %% exit(Port, shutdown),
    %% _ = os:cmd(?FMT("kill ~s", [Pid])),
    exit_loop(Port).

stop_all() ->
    _ = [ {ok, _} = stop(Ref) || {Ref, Sh} <- erlang:get(),
                                 is_record(Sh, sh)],
    ok.

expect(Ref, Regex) ->
    expect(Ref, Regex, []).

expect(Ref, Regex, RegexOpts) ->
    #sh{ port = Port } = erlang:get(Ref),
    expect_loop(Port, Regex, RegexOpts).

send(Ref, Line) ->
    #sh { port = Port } = erlang:get(Ref),
    port_command(Port, Line).


params(Params) ->
    params(Params, []).
params(Params, Opts) ->
    Sep = proplists:get_value(sep, Opts, " -- "),
    Eq = proplists:get_value(eq, Opts, "="),
    {Args, Ps} = lists:partition(fun is_tuple/1, Params),
    A = case Args of
            [] -> [];
            _ -> [args(Args, Eq), Sep]
        end,
    lists:flatten([ A, [ [argval(X), " "] || X <- Ps, X /= undefined ]]).

argval(N) when is_integer(N) ->
    io_lib:format("~b", [N]);
argval(A) ->
    io_lib:format("\"~s\"", [A]).

argkey(A) when is_atom(A) ->
    argkey(atom_to_list(A));
argkey(A) when is_binary(A) ->
    argkey(binary_to_list(A));
argkey([A]) ->
    io_lib:format("-~s", [[A]]);
argkey(S) ->
    io_lib:format("--~s", [S]).


args([], _Eq) ->
    [];
args([{_K, undefined} | List], Eq) ->
    args(List, Eq);
args([{A, V} | List], Eq) when is_atom(A) ->
    args([{atom_to_list(A), V} | List], Eq);
args([{A} | List], Eq) when is_atom(A) ->
    args([{atom_to_list(A)} | List], Eq);
args([A | List], Eq) when is_atom(A) ->
    args([atom_to_list(A) | List], Eq);
args([{K} | List], Eq) ->
    [ io_lib:format("~s ", [argkey(K)]) | args(List, Eq) ];
args([{K, V} | List], Eq) ->
    [ io_lib:format("~s~s~s ", [argkey(K), Eq, argval(V)]) | args(List, Eq) ].


%% ====================================================================
%% Internal functions
%% ====================================================================

patch_on_windows(Cmd, Env) ->
    case os:type() of
        {win32,nt} ->
            "cmd /q /c " ++ lists:foldl(fun({Key, Value}, Acc) ->
                                                expand_env_variable(Acc, Key, Value)
                                        end, Cmd, Env);
        _ ->
            Cmd
    end.

%%
%% Given env. variable FOO we want to expand all references to
%% it in InStr. References can have two forms: $FOO and ${FOO}
%% The end of form $FOO is delimited with whitespace or eol
%%
expand_env_variable(InStr, VarName, RawVarValue) ->
    case string:chr(InStr, $$) of
        0 ->
            %% No variables to expand
            InStr;
        _ ->
            VarValue = re:replace(RawVarValue, "\\\\", "\\\\\\\\", [global]),
            %% Use a regex to match/replace:
            %% Given variable "FOO": match $FOO\s | $FOOeol | ${FOO}
            RegEx = io_lib:format("\\\$(~s(\\s|$)|{~s})", [VarName, VarName]),
            ReOpts = [global, {return, list}],
            re:replace(InStr, RegEx, [VarValue, "\\2"], ReOpts)
    end.

expand_sh_flag(return_on_error) ->
    {error_handler,
     fun(_Command, Err) ->
             {error, Err}
     end};
expand_sh_flag({abort_on_error, Message}) ->
    {error_handler,
     log_msg_and_abort(Message)};
expand_sh_flag(abort_on_error) ->
    {error_handler,
     fun log_and_abort/2};
expand_sh_flag(use_stdout) ->
    {output_handler,
     fun(Line, Acc) ->
             io:format("~s", [Line]),
             [Line | Acc]
     end};
expand_sh_flag({use_stdout, false}) ->
    {output_handler,
     fun(Line, Acc) ->
             [Line | Acc]
     end};
expand_sh_flag({output_handler, Fun}) ->
    {output_handler,
     Fun};
expand_sh_flag({cd, _CdArg} = Cd) ->
    {port_settings, Cd};
expand_sh_flag({env, _EnvArg} = Env) ->
    {port_settings, Env}.

-type err_handler() :: fun((string(), {integer(), string()}) -> no_return()).
-spec log_msg_and_abort(string()) -> err_handler().
log_msg_and_abort(Message) ->
    fun(_Command, {Rc, _Output}) ->
            io:format(Message),
            error({return_code, Rc})
    end.

-spec log_and_abort(string(), {integer(), string()}) -> no_return().
log_and_abort(Command, {Rc, Output}) ->
    io:format("~s failed with error: ~w and output:~n~s~n",
              [Command, Rc, Output]),
    error({Rc, Output}).

sh_loop(Port, Fun, Acc) ->
    receive
        {Port, {data, {eol, Line}}} ->
            sh_loop(Port, Fun, Fun(Line ++ "\n", Acc));
        {Port, {data, {noeol, Line}}} ->
            sh_loop(Port, Fun, Fun(Line, Acc));
        {Port, {exit_status, 0}} ->
            {ok, lists:flatten(lists:reverse(Acc))};
        {Port, {exit_status, Rc}} ->
            {error, {Rc, lists:flatten(lists:reverse(Acc))}}
    end.

sh_loop(Port) ->
    receive
        {Port, {data, {_, _}}} ->
            sh_loop(Port);
        {Port, {exit_status, 0}} ->
            ok;
        {Port, {exit_status, Rc}} ->
            {error, Rc}
    end.

read_pid(Port) ->
    receive
        {Port, {data, {eol, Pid}}} ->
            Pid;
        {Port, {exit_status, Rc}} ->
            {error, {stopped, Rc}}
    end.

exit_loop(Port) ->
    receive
        {Port, {data, _}} ->
            exit_loop(Port);
        {Port, {exit_status, Rc}} ->
            {ok, Rc}
    end.

acc_loop(Port, Acc) ->
    receive
        {Port, {data, {_, Line}}} ->
            acc_loop(Port, [Line | Acc]);
        {Port, {exit_status, 0}} ->
            {ok, lists:reverse(Acc)};
        {Port, {exit_status, Rc}} ->
            {error, Rc};
        {Port, _Other} ->
            acc_loop(Port, Acc)
    end.


expect_loop(Port, Regex, RegexOpts) ->
    receive
        {Port, {data, {_Unknown, Line}}} ->
            case re:run(Line, Regex, RegexOpts) of
                {match, Captured} ->
                    {ok, Captured};
                match ->
                    {ok, Line};
                nomatch ->
                    expect_loop(Port, Regex, RegexOpts)
            end;
        {Port, {exit_status, Rc}} ->
            {error, {stopped, Rc}}
    end.
