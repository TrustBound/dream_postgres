-module(driver_fake_server_ffi).
-export([start/1, client_closed/1, start_silent/0, start_deaf/1,
         start_tls_then_bad_record/2, send_bad_record/1]).

%% A fake PostgreSQL server for the transport tests: it does one thing a
%% real server never does, then reports whether the client closed its end.
%%
%% start(Behavior) listens on a free port of localhost and gives
%% {Port, Reference}. The server accepts one connection, reads the
%% 8-byte SSLRequest, and then:
%%
%% - {answer, Bytes}: sends Bytes;
%% - reset: closes the socket with linger 0, so the client gets a reset;
%% - {tls, CertificateFile, KeyFile}: sends S and starts TLS with that
%%   certificate;
%% - not_tls: sends S, reads the client's TLS hello, and answers with bytes
%%   that are not TLS.
%%
%% It then waits for the client to close, and sends {Reference, closed}, or
%% {Reference, open} when 5 seconds pass first. After that it accepts one
%% more connection and keeps it open until the client closes it, for the
%% tests where the client connects again.
%%
%% start gives {ok, {Port, Reference}}, or {error, Reason} when the server
%% cannot listen. client_closed gives {ok, true} or {ok, false}, or
%% {error, Reason} when a step of the server failed. Reason is a text.
%%
%% start_silent() gives {ok, Port} of a server that accepts one connection
%% and never sends a byte, until the client closes, or {error, Reason}.

%% start_tls_then_bad_record(CertificateFile, KeyFile) gives
%% {ok, {Port, Server}} of a server that answers S, does the TLS handshake,
%% and waits. send_bad_record(Server) makes it send a record that no key of
%% the session protects, so the client's TLS layer raises an alert, and
%% gives {ok, nil} once it is sent. The test arms its read first, so the
%% alert reaches it in a fixed order.

-define(WAIT, 5000).

start(Behavior) ->
    Caller = self(),
    Reference = make_ref(),
    open(Caller, Reference, fun(Listen) ->
        Caller ! {Reference, serve(Listen, Behavior)},
        second_connection(Listen)
    end).

start_silent() ->
    Silent = fun(Listen) ->
        then(gen_tcp:accept(Listen, ?WAIT), fun(Socket) ->
            wait_for_close(gen_tcp, Socket)
        end),
        gen_tcp:close(Listen)
    end,
    case open(self(), make_ref(), Silent) of
        {ok, {Port, _Reference}} -> {ok, Port};
        {error, Reason} -> {error, Reason}
    end.

%% start_deaf(Bytes) gives {ok, Port} of a server that accepts one
%% connection, sends Bytes at once, and never reads a byte, so the
%% client's sends fill the buffers and block. It closes the connection
%% after ten seconds.
start_deaf(Bytes) ->
    Deaf = fun(Listen) ->
        then(gen_tcp:accept(Listen, ?WAIT), fun(Socket) ->
            gen_tcp:send(Socket, Bytes),
            receive after 10000 -> gen_tcp:close(Socket) end
        end),
        gen_tcp:close(Listen)
    end,
    case open(self(), make_ref(), Deaf) of
        {ok, {Port, _Reference}} -> {ok, Port};
        {error, Reason} -> {error, Reason}
    end.

start_tls_then_bad_record(CertificateFile, KeyFile) ->
    Caller = self(),
    Reference = make_ref(),
    Serve = fun(Listen) ->
        Caller ! {Reference, {server, self()}},
        Options = [{certfile, binary_to_list(CertificateFile)},
                   {keyfile, binary_to_list(KeyFile)},
                   {log_level, none}],
        then(gen_tcp:accept(Listen, ?WAIT), fun(Socket) ->
            then(gen_tcp:recv(Socket, 8, ?WAIT), fun(_Request) ->
                then(gen_tcp:send(Socket, <<"S">>), fun(_) ->
                    then(ssl:handshake(Socket, Options, ?WAIT), fun(TlsSocket) ->
                        send_record_on_command(Socket, TlsSocket)
                    end)
                end)
            end)
        end),
        gen_tcp:close(Listen)
    end,
    case open(Caller, Reference, Serve) of
        {ok, {Port, Reference}} -> server_of(Port, Reference);
        {error, Reason} -> {error, Reason}
    end.

server_of(Port, Reference) ->
    receive
        {Reference, {server, Server}} -> {ok, {Port, Server}}
    after ?WAIT -> {error, <<"the server gave no process within 5 seconds">>}
    end.

send_record_on_command(Socket, TlsSocket) ->
    receive
        {send_bad_record, From, Reference} ->
            %% A record header for application data, then 5 bytes that no
            %% key of the session protects.
            Sent = gen_tcp:send(Socket, <<23, 3, 3, 0, 5, "hello">>),
            From ! {Reference, Sent},
            wait_for_close(ssl, TlsSocket)
    after ?WAIT ->
        {error, <<"no command within 5 seconds">>}
    end.

send_bad_record(Server) ->
    Reference = make_ref(),
    Server ! {send_bad_record, self(), Reference},
    receive
        {Reference, ok} -> {ok, nil};
        {Reference, {error, Reason}} ->
            {error, unicode:characters_to_binary(io_lib:format("~p", [Reason]))}
    after ?WAIT -> {error, <<"the server did not send the record within 5 seconds">>}
    end.

%% Starts a process that listens on a free port and then runs Serve with
%% the listen socket. Gives {ok, {Port, Reference}} once it listens.
open(Caller, Reference, Serve) ->
    spawn(fun() -> listen(Caller, Reference, Serve) end),
    receive
        {Reference, {ready, Port}} -> {ok, {Port, Reference}};
        {Reference, {failed, Reason}} -> {error, Reason}
    end.

client_closed(Reference) ->
    receive
        {Reference, closed} -> {ok, true};
        {Reference, open} -> {ok, false};
        {Reference, {failed, Reason}} -> {error, Reason}
    end.

listen(Caller, Reference, Serve) ->
    Options = [binary, {active, false}, {reuseaddr, true}],
    case gen_tcp:listen(0, Options) of
        {ok, Listen} ->
            listening(Caller, Reference, Serve, Listen, inet:port(Listen));
        {error, Reason} ->
            Caller ! {Reference, failed(Reason)}
    end.

listening(Caller, Reference, Serve, Listen, {ok, Port}) ->
    Caller ! {Reference, {ready, Port}},
    Serve(Listen);
listening(Caller, Reference, _Serve, Listen, {error, Reason}) ->
    gen_tcp:close(Listen),
    Caller ! {Reference, failed(Reason)}.

serve(Listen, Behavior) ->
    then(gen_tcp:accept(Listen, ?WAIT), fun(Socket) ->
        then(gen_tcp:recv(Socket, 8, ?WAIT), fun(_Request) ->
            behave(Socket, Behavior)
        end)
    end).

behave(Socket, {answer, Bytes}) ->
    then(gen_tcp:send(Socket, Bytes), fun(_) ->
        wait_for_close(gen_tcp, Socket)
    end);
behave(Socket, reset) ->
    then(inet:setopts(Socket, [{linger, {true, 0}}]), fun(_) ->
        gen_tcp:close(Socket),
        closed
    end);
behave(Socket, not_tls) ->
    then(gen_tcp:send(Socket, <<"S">>), fun(_) ->
        then(gen_tcp:recv(Socket, 0, ?WAIT), fun(_Hello) ->
            then(gen_tcp:send(Socket, <<"this is not TLS">>), fun(_) ->
                wait_for_close(gen_tcp, Socket)
            end)
        end)
    end);
behave(Socket, {tls, CertificateFile, KeyFile}) ->
    Options = [{certfile, binary_to_list(CertificateFile)},
               {keyfile, binary_to_list(KeyFile)},
               {log_level, none}],
    then(gen_tcp:send(Socket, <<"S">>), fun(_) ->
        tls_handshake(ssl:handshake(Socket, Options, ?WAIT), Socket)
    end).

tls_handshake({ok, TlsSocket}, _Socket) -> wait_for_close(ssl, TlsSocket);
tls_handshake({error, _Reason}, Socket) -> wait_for_close(gen_tcp, Socket).

%% Runs Next with the value of a step that worked, or gives the failure of
%% a step that failed.
then(ok, Next) -> Next(ok);
then({ok, Value}, Next) -> Next(Value);
then({error, Reason}, _Next) -> failed(Reason).

failed(Reason) ->
    {failed, unicode:characters_to_binary(io_lib:format("~p", [Reason]))}.

wait_for_close(Module, Socket) ->
    case Module:recv(Socket, 0, ?WAIT) of
        {error, closed} -> closed;
        {error, timeout} -> open;
        {error, _Other} -> closed;
        {ok, _Bytes} -> wait_for_close(Module, Socket)
    end.

second_connection(Listen) ->
    case gen_tcp:accept(Listen, ?WAIT) of
        {ok, Socket} -> wait_for_close(gen_tcp, Socket);
        {error, _Reason} -> ok
    end,
    gen_tcp:close(Listen).
