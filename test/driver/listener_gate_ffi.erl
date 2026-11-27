-module(listener_gate_ffi).
-export([start/1, break/1, cut_first_query/1, answer_first_query/2,
         hold_first_query/1, wait_held/1, wait_refused/1, open/1, stop/1]).

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
%% - answer_first_query(Gate, Bytes): as cut_first_query, but the gate
%%   answers the first Query message with Bytes in place of the server,
%%   and the session goes on;
%% - hold_first_query(Gate): as cut_first_query, but the gate keeps the
%%   first Query message from the server and answers nothing, so the
%%   request after a reconnect gets no answer. The session goes on;
%% - wait_held(Gate): waits until the gate kept a Query message after
%%   hold_first_query;
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
cut_first_query(Gate) -> command(Gate, {first_query, cut}).
answer_first_query(Gate, Bytes) -> command(Gate, {first_query, {answer, Bytes}}).
hold_first_query(Gate) -> command(Gate, {first_query, {hold, Gate}}).
wait_held(Gate) -> command(Gate, wait_held).
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
    gate(Listen, ServerPort, open, [], none, pass, not_held);
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
%% what the relay of the next client does with its first Query: cut,
%% {answer, Bytes} or {hold, Gate}; else pass. Held is held once a relay
%% kept a Query, a {From, Reference} that waits for it, or not_held.
gate(Listen, ServerPort, Position, Relays, Waiter, Cut, Held) ->
    receive
        {accepted, Client} when Position =:= open ->
            Relay = spawn(fun() -> relay_start(ServerPort, Cut) end),
            Owned = gen_tcp:controlling_process(Client, Relay),
            Next = start_relay(Client, Relay, Owned, Relays),
            gate(Listen, ServerPort, Position, Next, Waiter, pass, Held);
        {accepted, Client} ->
            gen_tcp:close(Client),
            gate(Listen, ServerPort, refused, Relays, answer(Waiter), Cut, Held);
        held ->
            gate(Listen, ServerPort, Position, Relays, Waiter, Cut, answer_held(Held));
        {command, From, Reference, break} ->
            lists:foreach(fun close_relay/1, Relays),
            From ! {Reference, done},
            gate(Listen, ServerPort, closed, [], Waiter, Cut, Held);
        {command, From, Reference, {first_query, FirstQuery}} ->
            lists:foreach(fun close_relay/1, Relays),
            From ! {Reference, done},
            gate(Listen, ServerPort, open, [], Waiter, FirstQuery, Held);
        {command, From, Reference, wait_held} when Held =:= held ->
            From ! {Reference, done},
            gate(Listen, ServerPort, Position, Relays, Waiter, Cut, not_held);
        {command, From, Reference, wait_held} ->
            gate(Listen, ServerPort, Position, Relays, Waiter, Cut, {From, Reference});
        {command, From, Reference, wait_refused} when Position =:= refused ->
            From ! {Reference, done},
            gate(Listen, ServerPort, Position, Relays, Waiter, Cut, Held);
        {command, From, Reference, wait_refused} ->
            gate(Listen, ServerPort, Position, Relays, {From, Reference}, Cut, Held);
        {command, From, Reference, open} ->
            From ! {Reference, done},
            gate(Listen, ServerPort, open, Relays, Waiter, Cut, Held);
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

answer_held({From, Reference}) ->
    From ! {Reference, done},
    not_held;
answer_held(_HeldOrNotHeld) ->
    held.

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
%% with Q are the first request after the login. Cut says what happens to
%% them: cut closes both sockets, {answer, Bytes} sends Bytes to the
%% client, and {hold, Gate} keeps them and tells the gate. After an answer
%% or a hold the relay passes every byte.
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
    end;
relay(Client, Server, Cut) ->
    receive
        {tcp, Client, <<"Q", _/binary>>} ->
            first_query(Client, Server, Cut);
        {tcp, Client, Bytes} ->
            gen_tcp:send(Server, Bytes),
            inet:setopts(Client, [{active, once}]),
            relay(Client, Server, Cut);
        {tcp, Server, Bytes} ->
            gen_tcp:send(Client, Bytes),
            inet:setopts(Server, [{active, once}]),
            relay(Client, Server, Cut);
        close ->
            close_both(Client, Server);
        {tcp_closed, _Socket} ->
            close_both(Client, Server)
    end.

first_query(Client, Server, cut) ->
    close_both(Client, Server);
first_query(Client, Server, {answer, Bytes}) ->
    gen_tcp:send(Client, Bytes),
    inet:setopts(Client, [{active, once}]),
    relay(Client, Server, pass);
first_query(Client, Server, {hold, Gate}) ->
    Gate ! held,
    inet:setopts(Client, [{active, once}]),
    relay(Client, Server, pass).
close_both(Client, Server) ->
    gen_tcp:close(Client),
    gen_tcp:close(Server).

describe(Reason) ->
    unicode:characters_to_binary(io_lib:format("~p", [Reason])).
