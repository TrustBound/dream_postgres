-module(driver_fake_server_ffi).
-export([start/1, client_closed/1, start_silent/0]).

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

-define(WAIT, 5000).

start(Behavior) ->
    Caller = self(),
    Reference = make_ref(),
    Ready = make_ref(),
    spawn(fun() -> listen(Caller, Reference, Ready, Behavior) end),
    receive
        {Ready, Port} -> {Port, Reference}
    end.

client_closed(Reference) ->
    receive
        {Reference, closed} -> true;
        {Reference, open} -> false
    end.

listen(Caller, Reference, Ready, Behavior) ->
    {ok, Listen} = gen_tcp:listen(0, [binary, {active, false}, {reuseaddr, true}]),
    {ok, Port} = inet:port(Listen),
    Caller ! {Ready, Port},
    {ok, Socket} = gen_tcp:accept(Listen, ?WAIT),
    {ok, _Request} = gen_tcp:recv(Socket, 8, ?WAIT),
    Caller ! {Reference, behave(Socket, Behavior)},
    second_connection(Listen).

behave(Socket, {answer, Bytes}) ->
    ok = gen_tcp:send(Socket, Bytes),
    wait_for_close(gen_tcp, Socket);
behave(Socket, reset) ->
    ok = inet:setopts(Socket, [{linger, {true, 0}}]),
    gen_tcp:close(Socket),
    closed;
behave(Socket, not_tls) ->
    ok = gen_tcp:send(Socket, <<"S">>),
    {ok, _Hello} = gen_tcp:recv(Socket, 0, ?WAIT),
    ok = gen_tcp:send(Socket, <<"this is not TLS">>),
    wait_for_close(gen_tcp, Socket);
behave(Socket, {tls, CertificateFile, KeyFile}) ->
    ok = gen_tcp:send(Socket, <<"S">>),
    Options = [{certfile, binary_to_list(CertificateFile)},
               {keyfile, binary_to_list(KeyFile)},
               {log_level, none}],
    tls_handshake(ssl:handshake(Socket, Options, ?WAIT), Socket).

tls_handshake({ok, TlsSocket}, _Socket) -> wait_for_close(ssl, TlsSocket);
tls_handshake({error, _Reason}, Socket) -> wait_for_close(gen_tcp, Socket).

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

%% A server that accepts one connection and never sends a byte, until the
%% client closes. It gives its port.
start_silent() ->
    Caller = self(),
    Ready = make_ref(),
    spawn(fun() ->
        {ok, Listen} = gen_tcp:listen(0, [binary, {active, false}, {reuseaddr, true}]),
        {ok, Port} = inet:port(Listen),
        Caller ! {Ready, Port},
        {ok, Socket} = gen_tcp:accept(Listen, ?WAIT),
        wait_for_close(gen_tcp, Socket),
        gen_tcp:close(Listen)
    end),
    receive
        {Ready, Port} -> Port
    end.
