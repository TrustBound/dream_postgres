-module(database_ffi).
-export([get_env/1, run_in_own_process/1, halt/1, unique_integer/0,
         read_file/1, drop_pool_shutdown_reports/0, drop_pool_shutdown_report/2]).

%% Returns {ok, Value} for an environment variable that is set, and
%% {error, nil} for one that is not set or is empty.
get_env(Name) ->
    case os:getenv(binary_to_list(Name)) of
        false -> {error, nil};
        "" -> {error, nil};
        Value -> {ok, unicode:characters_to_binary(Value)}
    end.

%% Calls Fun in a new process and returns its value.
%%
%% A pool starts linked to the process that starts it, and it stays alive
%% when that process stops normally. The new process stops with the reason
%% `shutdown` after Fun returns, so each supervisor that Fun started stops
%% its pool and closes the connections to the server. Without this, the
%% pools of all tests stay open until the test run ends, and the server
%% refuses connections when they pass its `max_connections`.
run_in_own_process(Fun) ->
    Caller = self(),
    Ref = make_ref(),
    {Pid, Monitor} = spawn_monitor(fun() ->
        Caller ! {Ref, Fun()},
        exit(shutdown)
    end),
    receive
        {Ref, Value} ->
            erlang:demonitor(Monitor, [flush]),
            Value;
        {'DOWN', Monitor, process, Pid, Reason} ->
            erlang:error({run_in_own_process_failed, Reason})
    end.

%% Stops the BEAM with the exit status.
halt(Status) ->
    erlang:halt(Status).

%% Returns a positive integer that no other call in this BEAM returns.
unique_integer() ->
    erlang:unique_integer([positive]).

%% Returns {ok, Text} with the contents of the file, or {error, nil}.
read_file(Path) ->
    case file:read_file(Path) of
        {ok, Text} -> {ok, Text};
        {error, _Reason} -> {error, nil}
    end.

%% Drops the supervisor reports that pgo writes when a pool stops while a
%% connection loads its types. run_in_own_process/1 stops a pool after each
%% test, so without this filter the test output shows these reports, which
%% are not failures. Every other log event is kept.
drop_pool_shutdown_reports() ->
    _ = logger:remove_primary_filter(drop_pool_shutdown_reports),
    ok = logger:add_primary_filter(
        drop_pool_shutdown_reports,
        {fun ?MODULE:drop_pool_shutdown_report/2, nil}
    ),
    nil.

drop_pool_shutdown_report(
    #{msg := {report, #{label := {supervisor, shutdown_error}, report := Report}}},
    _Extra
) ->
    case proplists:get_value(supervisor, Report) of
        {_Pid, pgo_pool_sup} -> stop;
        _ -> ignore
    end;
drop_pool_shutdown_report(_Event, _Extra) ->
    ignore.
