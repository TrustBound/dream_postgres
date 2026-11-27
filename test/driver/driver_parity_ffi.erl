-module(driver_parity_ffi).
-export([start_login_refusing_server/0, start_closing_server/0,
         client_closed/1, status_holds/2, stop_process/1]).

%% Fake servers and process checks for the parity tests.
%%
%% start_login_refusing_server() listens on a free port of localhost and
%% gives {Port, Reference}. It accepts one connection, reads the
%% StartupMessage, answers with the ErrorResponse 28P01 and keeps its end
%% open. start_closing_server() does the same, but reads the 8-byte
%% SSLRequest and then shuts its sending side, as a server that closes
%% the connection. Both then wait for the client to close its socket, and
%% client_closed(Reference) gives true when it did within 5 seconds.

-define(WAIT, 5000).

start_login_refusing_server() ->
    start(fun refuse_login/1).

start_closing_server() ->
    start(fun close_after_tls_request/1).

client_closed(Reference) ->
    receive
        {Reference, closed} -> true;
        {Reference, open} -> false
    end.

start(Behave) ->
    Caller = self(),
    Reference = make_ref(),
    Ready = make_ref(),
    spawn(fun() -> listen(Caller, Reference, Ready, Behave) end),
    receive
        {Ready, Port} -> {Port, Reference}
    end.

listen(Caller, Reference, Ready, Behave) ->
    {ok, Listen} = gen_tcp:listen(0, [binary, {active, false}, {reuseaddr, true}]),
    {ok, Port} = inet:port(Listen),
    Caller ! {Ready, Port},
    {ok, Socket} = gen_tcp:accept(Listen, ?WAIT),
    Behave(Socket),
    Caller ! {Reference, wait_for_close(Socket)},
    gen_tcp:close(Listen).

refuse_login(Socket) ->
    {ok, <<Size:32>>} = gen_tcp:recv(Socket, 4, ?WAIT),
    {ok, _Startup} = gen_tcp:recv(Socket, Size - 4, ?WAIT),
    Fields = <<"SFATAL", 0, "VFATAL", 0, "C28P01", 0,
               "Mpassword authentication failed", 0, 0>>,
    ok = gen_tcp:send(Socket, <<"E", (byte_size(Fields) + 4):32, Fields/binary>>).

close_after_tls_request(Socket) ->
    {ok, _Request} = gen_tcp:recv(Socket, 8, ?WAIT),
    ok = gen_tcp:shutdown(Socket, write).

wait_for_close(Socket) ->
    case gen_tcp:recv(Socket, 0, ?WAIT) of
        {error, timeout} -> open;
        {error, _Closed} -> closed;
        {ok, _Bytes} -> wait_for_close(Socket)
    end.

%% True when the printed status of the process holds Text.
status_holds(Pid, Text) ->
    Status = sys:get_status(Pid, ?WAIT),
    Printed = unicode:characters_to_binary(io_lib:format("~p", [Status])),
    binary:match(Printed, Text) =/= nomatch.

%% Stops a linked process, such as a supervisor, without an exit signal
%% to the caller, and waits until it is gone.
stop_process(Pid) ->
    unlink(Pid),
    Monitor = monitor(process, Pid),
    exit(Pid, shutdown),
    receive
        {'DOWN', Monitor, process, Pid, _Reason} -> nil
    end.
