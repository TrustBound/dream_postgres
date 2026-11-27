-module(pool_proxy_ffi).
-export([start/1, freeze/1, next_kept/1, close_client/1, watch_client_end/1,
         client_end/1, stop/1]).

%% A TCP proxy between the connections of a pool and a driver server, for
%% the pool tests: it passes every byte both ways, and on a command it does
%% what a broken network does.
%%
%% start(ServerPort) listens on a free port of localhost and gives
%% {Port, Proxy}. The proxy accepts one client after the other, and
%% connects each one to the server.
%%
%% - freeze(Proxy) makes the proxy keep each byte that the client of now
%%   sends, and send nothing of it to the server, as a network that drops
%%   the client's packets. It gives a reference for next_kept.
%% - next_kept(Reference) waits until the client sent bytes that the
%%   proxy kept, and gives them.
%% - close_client(Proxy) closes the client's socket.
%% - watch_client_end(Proxy) asks for the last bytes that the client sends
%%   before it closes its socket; client_end(Watch) waits for them.
%% - stop(Proxy) ends the proxy: its listener and its sockets close, so a
%%   new connect is refused.
%%
%% Each command waits until the proxy did it. A new client is never frozen.

start(ServerPort) ->
    Caller = self(),
    Ready = make_ref(),
    Proxy = spawn(fun() -> listen(Caller, Ready, ServerPort) end),
    receive
        {Ready, Port} -> {Port, Proxy}
    end.

freeze(Proxy) ->
    Reference = make_ref(),
    command(Proxy, {freeze, self(), Reference}),
    Reference.

next_kept(Reference) ->
    receive
        {Reference, Bytes} -> Bytes
    end.

close_client(Proxy) -> command(Proxy, close_client).

watch_client_end(Proxy) ->
    Reference = make_ref(),
    Proxy ! {watch, self(), Reference},
    Reference.

client_end(Reference) ->
    receive
        {Reference, LastBytes} -> LastBytes
    end.

stop(Proxy) ->
    Monitor = erlang:monitor(process, Proxy),
    exit(Proxy, kill),
    receive
        {'DOWN', Monitor, process, Proxy, _Reason} -> nil
    end.

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

accept(Listen, ServerPort, Watch) ->
    {ok, Client} = gen_tcp:accept(Listen),
    {ok, Server} = gen_tcp:connect("localhost", ServerPort, [binary, {active, once}]),
    ok = inet:setopts(Client, [{active, once}]),
    NextWatch = loop(Client, Server, #{last => <<>>, watch => Watch, frozen => none}),
    accept(Listen, ServerPort, NextWatch).

loop(Client, Server, State) ->
    receive
        {tcp, Client, Bytes} ->
            pass_or_keep(maps:get(frozen, State), Server, Bytes),
            ok = inet:setopts(Client, [{active, once}]),
            loop(Client, Server, State#{last := Bytes});
        {tcp, Server, Bytes} ->
            gen_tcp:send(Client, Bytes),
            ok = inet:setopts(Server, [{active, once}]),
            loop(Client, Server, State);
        {command, From, Reference, {freeze, Keeper, KeepReference}} ->
            From ! {Reference, done},
            loop(Client, Server, State#{frozen := {Keeper, KeepReference}});
        {command, From, Reference, close_client} ->
            gen_tcp:close(Client),
            gen_tcp:close(Server),
            From ! {Reference, done},
            maps:get(watch, State);
        {watch, From, Reference} ->
            loop(Client, Server, State#{watch := {From, Reference}});
        {tcp_closed, Client} ->
            report_end(maps:get(watch, State), maps:get(last, State)),
            gen_tcp:close(Server),
            none;
        {tcp_closed, Server} ->
            gen_tcp:close(Client),
            maps:get(watch, State)
    end.

pass_or_keep(none, Server, Bytes) -> gen_tcp:send(Server, Bytes);
pass_or_keep({Keeper, Reference}, _Server, Bytes) -> Keeper ! {Reference, Bytes}.

report_end({From, Reference}, Last) -> From ! {Reference, Last};
report_end(none, _Last) -> ok.
