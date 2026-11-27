-module(driver_proxy_ffi).
-export([start/1, inject/2, close_client/1, reset_client/1, stop_reading/1,
         watch_client_end/1, client_end/1, stop/1]).

%% A TCP proxy between a connection process and a driver server, for the
%% connection tests: it passes every byte both ways, and on a command it
%% does what a broken network or server does.
%%
%% start(ServerPort) listens on a free port of localhost and gives
%% {Port, Proxy}. The proxy accepts one client, connects to the server, and
%% passes bytes until a command:
%%
%% - inject(Proxy, Bytes): sends Bytes to the client, as if the server sent
%%   them;
%% - close_client(Proxy): closes the client's socket;
%% - reset_client(Proxy): resets the client's socket (linger 0);
%% - stop_reading(Proxy): reads nothing more from the client, so its sends
%%   fill the buffers and block.
%%
%% Each command waits until the proxy did it.
%%
%% stop(Proxy) ends the proxy at once. Its sockets close with it, so the
%% server ends the session even when the proxy stopped reading, and saw
%% no close of the client.
%%
%% watch_client_end(Proxy) asks for the last bytes that the client sends
%% before it closes its socket; client_end(Watch) waits for them, so a test
%% can see whether a client ended with a Terminate.

start(ServerPort) ->
    Caller = self(),
    Ready = make_ref(),
    Proxy = spawn(fun() -> listen(Caller, Ready, ServerPort) end),
    receive
        {Ready, Port} -> {Port, Proxy}
    end.

inject(Proxy, Bytes) -> command(Proxy, {inject, Bytes}).
close_client(Proxy) -> command(Proxy, close_client).
reset_client(Proxy) -> command(Proxy, reset_client).
stop_reading(Proxy) -> command(Proxy, stop_reading).

watch_client_end(Proxy) ->
    Reference = make_ref(),
    Proxy ! {watch, self(), Reference},
    Reference.

client_end(Reference) ->
    receive
        {Reference, LastBytes} -> LastBytes
    end.

stop(Proxy) ->
    exit(Proxy, kill),
    nil.

command(Proxy, Command) ->
    Reference = make_ref(),
    Proxy ! {command, self(), Reference, Command},
    receive
        {Reference, done} -> nil
    end.

listen(Caller, Ready, ServerPort) ->
    {ok, Listen} = gen_tcp:listen(0, [binary, {active, false}, {reuseaddr, true}]),
    {ok, Port} = inet:port(Listen),
    Caller ! {Ready, Port},
    accept(Listen, ServerPort, none).

%% One client after the other: a client that connects again after a loss
%% gets a new session with the server.
accept(Listen, ServerPort, Watch) ->
    {ok, Client} = gen_tcp:accept(Listen),
    {ok, Server} = gen_tcp:connect("localhost", ServerPort, [binary, {active, once}]),
    ok = inet:setopts(Client, [{active, once}]),
    NextWatch = loop(Client, Server, <<>>, Watch),
    accept(Listen, ServerPort, NextWatch).

loop(Client, Server, Last, Watch) ->
    receive
        {tcp, Client, Bytes} ->
            ok = gen_tcp:send(Server, Bytes),
            ok = inet:setopts(Client, [{active, once}]),
            loop(Client, Server, Bytes, Watch);
        {tcp, Server, Bytes} ->
            gen_tcp:send(Client, Bytes),
            ok = inet:setopts(Server, [{active, once}]),
            loop(Client, Server, Last, Watch);
        {command, From, Reference, Command} ->
            Next = run(Command, Client),
            From ! {Reference, done},
            after_command(Next, Client, Server, Last, Watch);
        {watch, From, Reference} ->
            loop(Client, Server, Last, {From, Reference});
        {tcp_closed, Client} ->
            report_end(Watch, Last),
            gen_tcp:close(Server),
            none;
        {tcp_closed, Server} ->
            gen_tcp:close(Client),
            Watch
    end.

%% After a close or a reset the session is over, and the proxy waits for
%% the next client.
after_command(continue, Client, Server, Last, Watch) ->
    loop(Client, Server, Last, Watch);
after_command(ended, _Client, Server, _Last, Watch) ->
    gen_tcp:close(Server),
    Watch.

report_end({From, Reference}, Last) -> From ! {Reference, Last};
report_end(none, _Last) -> ok.

run({inject, Bytes}, Client) ->
    gen_tcp:send(Client, Bytes),
    continue;
run(close_client, Client) ->
    gen_tcp:close(Client),
    ended;
run(reset_client, Client) ->
    inet:setopts(Client, [{linger, {true, 0}}]),
    gen_tcp:close(Client),
    ended;
run(stop_reading, Client) ->
    inet:setopts(Client, [{active, false}, {recbuf, 1024}]),
    continue.
