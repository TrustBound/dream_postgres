-module(listener_gate_ffi).
-export([start/1, break/1, wait_refused/1, open/1, stop/1]).

%% A TCP proxy with a gate, for the listener tests: it passes every byte
%% both ways between each client and a driver server while the gate is
%% open, and closes each new client at once while the gate is closed, so a
%% reconnect fails until the test opens the gate again.
%%
%% start(ServerPort) listens on a free port of localhost and gives
%% {Port, Gate}, with the gate open.
%% - break(Gate): closes the gate and each client's connection, as a
%%   broken network does;
%% - wait_refused(Gate): waits until the closed gate closed a new client,
%%   so a reconnect failed;
%% - open(Gate): opens the gate, so the next client gets a session;
%% - stop(Gate): closes everything and ends the proxy.
%%
%% Each command waits until the proxy did it.

start(ServerPort) ->
    Caller = self(),
    Ready = make_ref(),
    Gate = spawn(fun() -> init(Caller, Ready, ServerPort) end),
    receive
        {Ready, Port} -> {Port, Gate}
    end.

break(Gate) -> command(Gate, break).
wait_refused(Gate) -> command(Gate, wait_refused).
open(Gate) -> command(Gate, open).
stop(Gate) -> command(Gate, stop).

command(Gate, Command) ->
    Reference = make_ref(),
    Gate ! {command, self(), Reference, Command},
    receive
        {Reference, done} -> nil
    end.

init(Caller, Ready, ServerPort) ->
    {ok, Listen} = gen_tcp:listen(0, [binary, {active, false}, {reuseaddr, true}]),
    {ok, Port} = inet:port(Listen),
    Gate = self(),
    spawn_link(fun() -> accept(Listen, Gate) end),
    Caller ! {Ready, Port},
    gate(Listen, ServerPort, open, [], none).

%% The acceptor gives each client to the gate.
accept(Listen, Gate) ->
    case gen_tcp:accept(Listen) of
        {ok, Client} ->
            ok = gen_tcp:controlling_process(Client, Gate),
            Gate ! {accepted, Client},
            accept(Listen, Gate);
        {error, closed} ->
            ok
    end.

%% Waiter is the command that waits for a refused client, or none.
gate(Listen, ServerPort, Position, Relays, Waiter) ->
    receive
        {accepted, Client} when Position =:= open ->
            Relay = spawn(fun() -> relay_start(ServerPort) end),
            ok = gen_tcp:controlling_process(Client, Relay),
            Relay ! {client, Client},
            gate(Listen, ServerPort, Position, [Relay | Relays], Waiter);
        {accepted, Client} ->
            gen_tcp:close(Client),
            gate(Listen, ServerPort, refused, Relays, answer(Waiter));
        {command, From, Reference, break} ->
            lists:foreach(fun close_relay/1, Relays),
            From ! {Reference, done},
            gate(Listen, ServerPort, closed, [], Waiter);
        {command, From, Reference, wait_refused} when Position =:= refused ->
            From ! {Reference, done},
            gate(Listen, ServerPort, Position, Relays, Waiter);
        {command, From, Reference, wait_refused} ->
            gate(Listen, ServerPort, Position, Relays, {From, Reference});
        {command, From, Reference, open} ->
            From ! {Reference, done},
            gate(Listen, ServerPort, open, Relays, Waiter);
        {command, From, Reference, stop} ->
            lists:foreach(fun close_relay/1, Relays),
            gen_tcp:close(Listen),
            From ! {Reference, done}
    end.

answer({From, Reference}) ->
    From ! {Reference, done},
    none;
answer(none) ->
    none.

%% Waits until the relay is gone, also when it ended by itself before.
close_relay(Relay) ->
    Monitor = erlang:monitor(process, Relay),
    Relay ! close,
    receive
        {'DOWN', Monitor, process, Relay, _Reason} -> ok
    end.

relay_start(ServerPort) ->
    receive
        {client, Client} ->
            {ok, Server} = gen_tcp:connect("localhost", ServerPort, [binary, {active, once}]),
            ok = inet:setopts(Client, [{active, once}]),
            relay(Client, Server);
        close ->
            ok
    end.

relay(Client, Server) ->
    receive
        {tcp, Client, Bytes} ->
            gen_tcp:send(Server, Bytes),
            inet:setopts(Client, [{active, once}]),
            relay(Client, Server);
        {tcp, Server, Bytes} ->
            gen_tcp:send(Client, Bytes),
            inet:setopts(Server, [{active, once}]),
            relay(Client, Server);
        close ->
            gen_tcp:close(Client),
            gen_tcp:close(Server);
        {tcp_closed, _Socket} ->
            gen_tcp:close(Client),
            gen_tcp:close(Server)
    end.
