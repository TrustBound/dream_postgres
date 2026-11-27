-module(driver_parity_ffi).
-export([start_login_refusing_server/0, start_closing_server/0,
         printed_status/1, stop_process/1]).

%% Fake servers and process checks for the parity tests.
%%
%% start_login_refusing_server() listens on a free port of localhost and
%% gives {ok, {Port, Reference}}, or {error, Reason} as a text when it
%% cannot listen. It accepts one connection, reads the StartupMessage,
%% answers with the ErrorResponse 28P01 and keeps its end open.
%% start_closing_server() does the same, but reads the 8-byte SSLRequest
%% and then shuts its sending side, as a server that closes the
%% connection. Both then wait for the client to close its socket, and send
%% {Reference, closed}, or {Reference, open} when 5 seconds pass first, or
%% {Reference, {failed, Reason}} when a step failed, as
%% driver_fake_server_ffi does: its client_closed reads it.

-define(WAIT, 5000).

start_login_refusing_server() ->
    start(fun refuse_login/1).

start_closing_server() ->
    start(fun close_after_tls_request/1).

start(Behave) ->
    Caller = self(),
    Reference = make_ref(),
    spawn(fun() -> listen(Caller, Reference, Behave) end),
    receive
        {Reference, {ready, Port}} -> {ok, {Port, Reference}};
        {Reference, {failed, Reason}} -> {error, Reason}
    end.

listen(Caller, Reference, Behave) ->
    Options = [binary, {active, false}, {reuseaddr, true}],
    case gen_tcp:listen(0, Options) of
        {ok, Listen} ->
            listening(Caller, Reference, Behave, Listen, inet:port(Listen));
        {error, Reason} ->
            Caller ! {Reference, failed(Reason)}
    end.

listening(Caller, Reference, Behave, Listen, {ok, Port}) ->
    Caller ! {Reference, {ready, Port}},
    Caller ! {Reference, serve(Listen, Behave)},
    gen_tcp:close(Listen);
listening(Caller, Reference, _Behave, Listen, {error, Reason}) ->
    gen_tcp:close(Listen),
    Caller ! {Reference, failed(Reason)}.

serve(Listen, Behave) ->
    then(gen_tcp:accept(Listen, ?WAIT), fun(Socket) ->
        then(Behave(Socket), fun(_) -> wait_for_close(Socket) end)
    end).

refuse_login(Socket) ->
    then(gen_tcp:recv(Socket, 4, ?WAIT), fun(<<Size:32>>) ->
        then(gen_tcp:recv(Socket, Size - 4, ?WAIT), fun(_Startup) ->
            Fields = <<"SFATAL", 0, "VFATAL", 0, "C28P01", 0,
                       "Mpassword authentication failed", 0, 0>>,
            gen_tcp:send(Socket,
                         <<"E", (byte_size(Fields) + 4):32, Fields/binary>>)
        end)
    end).

close_after_tls_request(Socket) ->
    then(gen_tcp:recv(Socket, 8, ?WAIT), fun(_Request) ->
        gen_tcp:shutdown(Socket, write)
    end).

%% Runs Next with the value of a step that worked, or gives the failure of
%% a step that failed.
then(ok, Next) -> Next(ok);
then({ok, Value}, Next) -> Next(Value);
then({error, Reason}, _Next) -> failed(Reason);
then({failed, Reason}, _Next) -> {failed, Reason}.

failed(Reason) ->
    {failed, unicode:characters_to_binary(io_lib:format("~p", [Reason]))}.

wait_for_close(Socket) ->
    case gen_tcp:recv(Socket, 0, ?WAIT) of
        {error, timeout} -> open;
        {error, _Closed} -> closed;
        {ok, _Bytes} -> wait_for_close(Socket)
    end.

%% The status of the process, printed with ~p.
printed_status(Pid) ->
    Status = sys:get_status(Pid, ?WAIT),
    unicode:characters_to_binary(io_lib:format("~p", [Status])).

%% Stops a linked process, such as a supervisor, without an exit signal
%% to the caller, and waits until it is gone.
stop_process(Pid) ->
    unlink(Pid),
    Monitor = monitor(process, Pid),
    exit(Pid, shutdown),
    receive
        {'DOWN', Monitor, process, Pid, _Reason} -> nil
    end.
