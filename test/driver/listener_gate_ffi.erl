-module(listener_gate_ffi).
-export([start/1, break/1, cut_first_query/1, wait_refused/1, open/1, stop/1]).

%% A TCP proxy with a gate, for the listener tests: it passes every byte
%% both ways between each client and a driver server while the gate is
%% open, and closes each new client at once while the gate is closed, so a
%% reconnect fails until the test opens the gate again.
%%
%% start(ServerPort) listens on a free port of localhost and gives
%% {ok, {Port, Gate}}, with the gate open, or {error, Reason} as a text
%% when it cannot listen.
%% - break(Gate): closes the gate and each client's connection, as a
%%   broken network does;
%% - cut_first_query(Gate): closes each client's connection, as break
%%   does, but leaves the gate open. The next client passes its login,
%%   and the gate closes it at its first Query message, so the request
%%   after a reconnect meets a loss. The client after it passes again;
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
        {Ready, {ok, Port}} -> {ok, {Port, Gate}};
        {Ready, {error, Reason}} -> {error, describe(Reason)}
    end.

break(Gate) -> command(Gate, break).
cut_first_query(Gate) -> command(Gate, cut_first_query).
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
    case gen_tcp:listen(0, [binary, {active, false}, {reuseaddr, true}]) of
        {ok, Listen} ->
            listening(Caller, Ready, ServerPort, Listen, inet:port(Listen));
        {error, Reason} ->
            Caller ! {Ready, {error, Reason}}
    end.

listening(Caller, Ready, ServerPort, Listen, {ok, Port}) ->
    Gate = self(),
    spawn_link(fun() -> accept(Listen, Gate) end),
    Caller ! {Ready, {ok, Port}},
    gate(Listen, ServerPort, open, [], none, pass);
listening(Caller, Ready, _ServerPort, Listen, {error, Reason}) ->
    gen_tcp:close(Listen),
    Caller ! {Ready, {error, Reason}}.

%% The acceptor gives each client to the gate. A client that the gate
%% cannot own is closed, so it sees a lost connection. A failed accept ends
%% the acceptor.
accept(Listen, Gate) ->
    case gen_tcp:accept(Listen) of
        {ok, Client} ->
            give_client(Client, Gate, gen_tcp:controlling_process(Client, Gate)),
            accept(Listen, Gate);
        {error, _Reason} ->
            ok
    end.

give_client(Client, Gate, ok) -> Gate ! {accepted, Client};
give_client(Client, _Gate, {error, _Reason}) -> gen_tcp:close(Client).

%% Waiter is the command that waits for a refused client, or none. Cut is
%% cut when the next client is closed at its first Query, else pass.
gate(Listen, ServerPort, Position, Relays, Waiter, Cut) ->
    receive
        {accepted, Client} when Position =:= open ->
            Relay = spawn(fun() -> relay_start(ServerPort, Cut) end),
            Owned = gen_tcp:controlling_process(Client, Relay),
            Next = start_relay(Client, Relay, Owned, Relays),
            gate(Listen, ServerPort, Position, Next, Waiter, pass);
        {accepted, Client} ->
            gen_tcp:close(Client),
            gate(Listen, ServerPort, refused, Relays, answer(Waiter), Cut);
        {command, From, Reference, break} ->
            lists:foreach(fun close_relay/1, Relays),
            From ! {Reference, done},
            gate(Listen, ServerPort, closed, [], Waiter, Cut);
        {command, From, Reference, cut_first_query} ->
            lists:foreach(fun close_relay/1, Relays),
            From ! {Reference, done},
            gate(Listen, ServerPort, open, [], Waiter, cut);
        {command, From, Reference, wait_refused} when Position =:= refused ->
            From ! {Reference, done},
            gate(Listen, ServerPort, Position, Relays, Waiter, Cut);
        {command, From, Reference, wait_refused} ->
            gate(Listen, ServerPort, Position, Relays, {From, Reference}, Cut);
        {command, From, Reference, open} ->
            From ! {Reference, done},
            gate(Listen, ServerPort, open, Relays, Waiter, Cut);
        {command, From, Reference, stop} ->
            lists:foreach(fun close_relay/1, Relays),
            gen_tcp:close(Listen),
            From ! {Reference, done}
    end.

%% A client that the relay cannot own is closed, and the relay ends.
start_relay(Client, Relay, ok, Relays) ->
    Relay ! {client, Client},
    [Relay | Relays];
start_relay(Client, Relay, {error, _Reason}, Relays) ->
    gen_tcp:close(Client),
    Relay ! close,
    Relays.

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

%% A client whose server connection fails is closed, so it sees a lost
%% connection, and the relay ends.
relay_start(ServerPort, Cut) ->
    receive
        {client, Client} ->
            Connected = gen_tcp:connect("localhost", ServerPort, [binary, {active, once}]),
            relay_connected(Client, Connected, Cut);
        close ->
            ok
    end.

relay_connected(Client, {ok, Server}, Cut) ->
    case inet:setopts(Client, [{active, once}]) of
        ok -> relay(Client, Server, Cut);
        {error, _Reason} -> close_both(Client, Server)
    end;
relay_connected(Client, {error, _Reason}, _Cut) ->
    gen_tcp:close(Client).

%% A login sends no Query, so the first bytes of the client that start
%% with Q are the first request after the login.
relay(Client, Server, cut) ->
    receive
        {tcp, Client, <<"Q", _/binary>>} ->
            close_both(Client, Server);
        {tcp, Client, Bytes} ->
            gen_tcp:send(Server, Bytes),
            inet:setopts(Client, [{active, once}]),
            relay(Client, Server, cut);
        {tcp, Server, Bytes} ->
            gen_tcp:send(Client, Bytes),
            inet:setopts(Server, [{active, once}]),
            relay(Client, Server, cut);
        close ->
            close_both(Client, Server);
        {tcp_closed, _Socket} ->
            close_both(Client, Server)
    end;
relay(Client, Server, pass) ->
    receive
        {tcp, Client, Bytes} ->
            gen_tcp:send(Server, Bytes),
            inet:setopts(Client, [{active, once}]),
            relay(Client, Server, pass);
        {tcp, Server, Bytes} ->
            gen_tcp:send(Client, Bytes),
            inet:setopts(Server, [{active, once}]),
            relay(Client, Server, pass);
        close ->
            close_both(Client, Server);
        {tcp_closed, _Socket} ->
            close_both(Client, Server)
    end.

close_both(Client, Server) ->
    gen_tcp:close(Client),
    gen_tcp:close(Server).

describe(Reason) ->
    unicode:characters_to_binary(io_lib:format("~p", [Reason])).
