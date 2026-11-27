-module(driver_cancel_gate_ffi).
-export([start/1, record/1, release/1, events/1, stop/1]).

%% A proxy for the cancel tests. The first client is the connection: the
%% gate passes its bytes both ways. Each later client is a cancel: the
%% gate holds it, and passes it to the server only after release/1, so a
%% test decides when a cancel reaches the server.
%%
%% After record/1, the gate notes in order each chunk of bytes that the
%% connection sends to the server (main_bytes) and the moment it passes a
%% held cancel on (cancel_passed). events/1 gives those notes.
%%
%% start(ServerPort) gives {ok, {Port, Gate}}, or {error, Reason} as a
%% text when the gate cannot listen.
%%
%% stop/1 ends the gate, which closes every socket that it owns. The gate
%% also ends by itself when the connection closes, or when a step for the
%% connection fails (then it closes the connection's socket, so the
%% connection sees a lost connection). A command to a gate that ended
%% gives nil at once.

start(ServerPort) ->
    Caller = self(),
    Ready = make_ref(),
    Gate = spawn(fun() -> init(Caller, Ready, ServerPort) end),
    receive
        {Ready, {ok, Port}} -> {ok, {Port, Gate}};
        {Ready, {error, Reason}} -> {error, describe(Reason)}
    end.

record(Gate) -> call(Gate, record).
release(Gate) -> call(Gate, release).
events(Gate) -> call(Gate, events).
stop(Gate) -> call(Gate, stop).

call(Gate, Command) ->
    Reference = erlang:monitor(process, Gate),
    Gate ! {command, self(), Reference, Command},
    receive
        {Reference, Answer} ->
            erlang:demonitor(Reference, [flush]),
            Answer;
        {'DOWN', Reference, process, Gate, _Reason} ->
            nil
    end.

init(Caller, Ready, ServerPort) ->
    case gen_tcp:listen(0, [binary, {active, false}, {reuseaddr, true}]) of
        {ok, Listen} ->
            listening(Caller, Ready, ServerPort, Listen, inet:port(Listen));
        {error, Reason} ->
            Caller ! {Ready, {error, Reason}}
    end.

listening(Caller, Ready, ServerPort, Listen, {ok, Port}) ->
    Caller ! {Ready, {ok, Port}},
    Gate = self(),
    spawn_link(fun() -> accept_loop(Listen, Gate) end),
    loop(#{server_port => ServerPort, main => none, held => [],
           recording => false, events => []});
listening(Caller, Ready, _ServerPort, Listen, {error, Reason}) ->
    gen_tcp:close(Listen),
    Caller ! {Ready, {error, Reason}}.

%% The loop ends when the gate ends, because that closes the listening
%% socket. A client that the gate cannot own is closed.
accept_loop(Listen, Gate) ->
    case gen_tcp:accept(Listen) of
        {ok, Client} ->
            give_client(Client, Gate, gen_tcp:controlling_process(Client, Gate)),
            accept_loop(Listen, Gate);
        {error, _Reason} ->
            ok
    end.

give_client(Client, Gate, ok) -> Gate ! {accepted, Client};
give_client(Client, _Gate, {error, _Reason}) -> gen_tcp:close(Client).

loop(State = #{main := none, server_port := ServerPort}) ->
    receive
        {accepted, Client} ->
            Connected = gen_tcp:connect("localhost", ServerPort, [binary, {active, true}]),
            main_connected(State, Client, Connected);
        {command, From, Reference, stop} ->
            From ! {Reference, nil}
    end;
loop(State = #{main := {Client, Server}}) ->
    receive
        {accepted, Cancel} ->
            loop(State#{held := [Cancel | maps:get(held, State)]});
        {tcp, Client, Bytes} ->
            main_sent(State, Client, Server, gen_tcp:send(Server, Bytes));
        {tcp, Server, Bytes} ->
            gen_tcp:send(Client, Bytes),
            loop(State);
        {tcp, Other, Bytes} ->
            forward_cancel(Other, Bytes, State),
            loop(State);
        {tcp_closed, Other} when Other =/= Client, Other =/= Server ->
            loop(State);
        {command, From, Reference, record} ->
            From ! {Reference, nil},
            loop(State#{recording := true});
        {command, From, Reference, release} ->
            State2 = release_held(State),
            From ! {Reference, nil},
            loop(State2);
        {command, From, Reference, events} ->
            From ! {Reference, lists:reverse(maps:get(events, State))},
            loop(State);
        {command, From, Reference, stop} ->
            From ! {Reference, nil};
        {tcp_closed, _Socket} ->
            ok
    end.

%% A failed step for the connection ends the gate, as a close does.
main_connected(State, Client, {ok, Server}) ->
    case inet:setopts(Client, [{active, true}]) of
        ok -> loop(State#{main := {Client, Server}});
        {error, _Reason} -> close_both(Client, Server)
    end;
main_connected(_State, Client, {error, _Reason}) ->
    gen_tcp:close(Client).

main_sent(State, _Client, _Server, ok) ->
    loop(note(State, main_bytes));
main_sent(_State, Client, Server, {error, _Reason}) ->
    close_both(Client, Server).

close_both(Client, Server) ->
    gen_tcp:close(Client),
    gen_tcp:close(Server).

note(State = #{recording := true, events := Events}, Event) ->
    State#{events := [Event | Events]};
note(State, _Event) ->
    State.

%% Each held cancel gets its own upstream socket; the gate relays the
%% cancel's bytes and the server's close back to the driver.
release_held(State = #{held := Held, server_port := ServerPort}) ->
    lists:foreach(fun(Cancel) -> relay(Cancel, ServerPort) end, Held),
    note(State#{held := []}, cancel_passed).

%% A cancel that the relay cannot own, or whose server connection fails,
%% is closed, so the driver sees its cancel fail.
relay(Cancel, ServerPort) ->
    Owner = self(),
    Pid = spawn(fun() -> relay_loop(Cancel, ServerPort) end),
    start_relay(Cancel, Pid, Owner, gen_tcp:controlling_process(Cancel, Pid)).

start_relay(_Cancel, Pid, Owner, ok) ->
    Pid ! {go, Owner};
start_relay(Cancel, Pid, _Owner, {error, _Reason}) ->
    exit(Pid, kill),
    gen_tcp:close(Cancel).

relay_loop(Cancel, ServerPort) ->
    receive {go, _Owner} -> ok end,
    Connected = gen_tcp:connect("localhost", ServerPort, [binary, {active, true}]),
    relay_connected(Cancel, Connected).

relay_connected(Cancel, {ok, Server}) ->
    case inet:setopts(Cancel, [{active, true}]) of
        ok -> relay_bytes(Cancel, Server);
        {error, _Reason} -> close_both(Cancel, Server)
    end;
relay_connected(Cancel, {error, _Reason}) ->
    gen_tcp:close(Cancel).

relay_bytes(Cancel, Server) ->
    receive
        {tcp, Cancel, Bytes} -> gen_tcp:send(Server, Bytes), relay_bytes(Cancel, Server);
        {tcp, Server, Bytes} -> gen_tcp:send(Cancel, Bytes), relay_bytes(Cancel, Server);
        {tcp_closed, Server} -> gen_tcp:close(Cancel);
        {tcp_closed, Cancel} -> gen_tcp:close(Server)
    end.

forward_cancel(_Other, _Bytes, _State) ->
    ok.

describe(Reason) ->
    unicode:characters_to_binary(io_lib:format("~p", [Reason])).
