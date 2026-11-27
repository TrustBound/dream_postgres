-module(driver_reconnect_server_ffi).
-export([start/1, wait_for_second_connection/1, start_silent/0,
         wait_for_connection/1, kill_linked_process/1, linked_process/1,
         monitor_count/1, monitored_by_count/1]).

%% A fake PostgreSQL server for the tests of the setup deadline on a
%% reconnect. start(SecondBehavior) listens on a free port of localhost and
%% gives {ok, {Port, Server}}, or {error, Reason}. The server:
%%
%% 1. accepts one connection, reads the StartupMessage, answers with a
%%    login that needs no password (AuthenticationOk, ReadyForQuery), and
%%    closes the connection, so the client loses it and connects again;
%% 2. accepts the second connection, tells wait_for_second_connection, and
%%    then, as SecondBehavior says:
%%    - silent: sends nothing;
%%    - {trickle, Head, IntervalMilliseconds}: sends Head, then one byte
%%      each interval, so a message is never complete;
%%    until the client closes. Then it stops listening, so a later connect
%%    is refused.

-define(WAIT, 5000).
-define(LOGIN, <<"R", 8:32, 0:32, "Z", 5:32, "I">>).

start(SecondBehavior) ->
    Caller = self(),
    Reference = make_ref(),
    case gen_tcp:listen(0, [binary, {active, false}, {reuseaddr, true}]) of
        {ok, Listen} -> started(Caller, Reference, Listen, SecondBehavior);
        {error, Reason} -> {error, reason_text(Reason)}
    end.

started(Caller, Reference, Listen, SecondBehavior) ->
    case inet:port(Listen) of
        {ok, Port} ->
            Server = spawn(fun() -> serve(Caller, Reference, SecondBehavior) end),
            handed_over(gen_tcp:controlling_process(Listen, Server), Listen,
                        Server, Reference, Port);
        {error, Reason} ->
            gen_tcp:close(Listen),
            {error, reason_text(Reason)}
    end.

handed_over(ok, Listen, Server, Reference, Port) ->
    Server ! {Reference, Listen},
    {ok, {Port, {Server, Reference}}};
handed_over({error, Reason}, Listen, Server, _Reference, _Port) ->
    exit(Server, kill),
    gen_tcp:close(Listen),
    {error, reason_text(Reason)}.

wait_for_second_connection({_Server, Reference}) ->
    receive
        {Reference, second_connection} -> {ok, nil};
        {Reference, {failed, Reason}} -> {error, Reason}
    after ?WAIT -> {error, <<"no second connection within 5 seconds">>}
    end.

serve(Caller, Reference, SecondBehavior) ->
    receive
        {Reference, Listen} ->
            Result = first_then_second(Caller, Reference, Listen, SecondBehavior),
            report_failure(Caller, Reference, Result),
            gen_tcp:close(Listen)
    end.

first_then_second(Caller, Reference, Listen, SecondBehavior) ->
    case log_in_and_close(Listen) of
        ok -> second(Caller, Reference, Listen, SecondBehavior);
        {error, Reason} -> {error, Reason}
    end.

log_in_and_close(Listen) ->
    case gen_tcp:accept(Listen, ?WAIT) of
        {ok, Socket} ->
            Answered = answer_login(Socket),
            gen_tcp:close(Socket),
            Answered;
        {error, Reason} ->
            {error, reason_text(Reason)}
    end.

answer_login(Socket) ->
    case gen_tcp:recv(Socket, 0, ?WAIT) of
        {ok, _StartupMessage} -> sent(gen_tcp:send(Socket, ?LOGIN));
        {error, Reason} -> {error, reason_text(Reason)}
    end.

second(Caller, Reference, Listen, SecondBehavior) ->
    case gen_tcp:accept(Listen, ?WAIT) of
        {ok, Socket} ->
            Caller ! {Reference, second_connection},
            behave(Socket, SecondBehavior),
            gen_tcp:close(Socket),
            ok;
        {error, Reason} ->
            {error, reason_text(Reason)}
    end.

behave(Socket, silent) ->
    wait_for_close(Socket, infinity);
behave(Socket, {trickle, Head, Interval}) ->
    trickle(Socket, gen_tcp:send(Socket, Head), Interval).

trickle(Socket, ok, Interval) ->
    case wait_for_close(Socket, Interval) of
        closed -> closed;
        open -> trickle(Socket, gen_tcp:send(Socket, <<"a">>), Interval)
    end;
trickle(_Socket, {error, _Reason}, _Interval) ->
    closed.

wait_for_close(Socket, Timeout) ->
    case gen_tcp:recv(Socket, 0, Timeout) of
        {error, timeout} -> open;
        {error, _Closed} -> closed;
        {ok, _Bytes} -> wait_for_close(Socket, Timeout)
    end.

sent(ok) -> ok;
sent({error, Reason}) -> {error, reason_text(Reason)}.

report_failure(_Caller, _Reference, ok) -> ok;
report_failure(Caller, Reference, {error, Reason}) ->
    Caller ! {Reference, {failed, Reason}}.

reason_text(Reason) -> unicode:characters_to_binary(io_lib:format("~p", [Reason])).

%% A server that accepts one connection, tells wait_for_connection, and
%% never sends a byte, until the client closes. It gives
%% {ok, {Port, Server}}, or {error, Reason}.
start_silent() ->
    Caller = self(),
    Reference = make_ref(),
    case gen_tcp:listen(0, [binary, {active, false}, {reuseaddr, true}]) of
        {ok, Listen} -> started_silent(Caller, Reference, Listen);
        {error, Reason} -> {error, reason_text(Reason)}
    end.

started_silent(Caller, Reference, Listen) ->
    case inet:port(Listen) of
        {ok, Port} ->
            Server = spawn(fun() -> serve_silent(Caller, Reference) end),
            handed_over(gen_tcp:controlling_process(Listen, Server), Listen,
                        Server, Reference, Port);
        {error, Reason} ->
            gen_tcp:close(Listen),
            {error, reason_text(Reason)}
    end.

serve_silent(Caller, Reference) ->
    receive
        {Reference, Listen} ->
            accept_silent(Caller, Reference, gen_tcp:accept(Listen, ?WAIT)),
            gen_tcp:close(Listen)
    end.

accept_silent(Caller, Reference, {ok, Socket}) ->
    Caller ! {Reference, connected},
    wait_for_close(Socket, infinity),
    gen_tcp:close(Socket);
accept_silent(Caller, Reference, {error, Reason}) ->
    Caller ! {Reference, {failed, reason_text(Reason)}}.

wait_for_connection({_Server, Reference}) ->
    receive
        {Reference, connected} -> {ok, nil};
        {Reference, {failed, Reason}} -> {error, Reason}
    after ?WAIT -> {error, <<"no connection within 5 seconds">>}
    end.

%% Kills the one process that Pid links to, for example the connection
%% process that a starter waits for.
kill_linked_process(Pid) ->
    case erlang:process_info(Pid, links) of
        {links, [Linked]} when is_pid(Linked) ->
            exit(Linked, kill),
            {ok, nil};
        Other ->
            {error, reason_text(Other)}
    end.

%% The one process that Pid links to.
linked_process(Pid) ->
    case erlang:process_info(Pid, links) of
        {links, [Linked]} when is_pid(Linked) -> {ok, Linked};
        Other -> {error, reason_text(Other)}
    end.

%% How many monitors Pid holds on other processes.
monitor_count(Pid) ->
    case erlang:process_info(Pid, monitors) of
        {monitors, Monitors} -> {ok, length(Monitors)};
        undefined -> {error, <<"the process is gone">>}
    end.

%% How many monitors other processes hold on Pid.
monitored_by_count(Pid) ->
    case erlang:process_info(Pid, monitored_by) of
        {monitored_by, Monitors} -> {ok, length(Monitors)};
        undefined -> {error, <<"the process is gone">>}
    end.
