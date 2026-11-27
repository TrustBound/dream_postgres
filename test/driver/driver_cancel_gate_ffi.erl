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
%% stop/1 ends the gate, which closes every socket that it owns. The gate
%% also ends by itself when the connection closes, so a command to a gate
%% that ended gives nil at once.

start(ServerPort) ->
    Caller = self(),
    Ready = make_ref(),
    Gate = spawn(fun() -> init(Caller, Ready, ServerPort) end),
    receive {Ready, Port} -> {Port, Gate} end.

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
    {ok, Listen} = gen_tcp:listen(0, [binary, {active, false}, {reuseaddr, true}]),
    {ok, Port} = inet:port(Listen),
    Caller ! {Ready, Port},
    Gate = self(),
    spawn_link(fun() -> accept_loop(Listen, Gate) end),
    loop(#{server_port => ServerPort, main => none, held => [],
           recording => false, events => []}).

accept_loop(Listen, Gate) ->
    {ok, Client} = gen_tcp:accept(Listen),
    ok = gen_tcp:controlling_process(Client, Gate),
    Gate ! {accepted, Client},
    accept_loop(Listen, Gate).

loop(State = #{main := none, server_port := ServerPort}) ->
    receive
        {accepted, Client} ->
            {ok, Server} = gen_tcp:connect("localhost", ServerPort, [binary, {active, true}]),
            ok = inet:setopts(Client, [{active, true}]),
            loop(State#{main := {Client, Server}});
        {command, From, Reference, stop} ->
            From ! {Reference, nil}
    end;
loop(State = #{main := {Client, Server}}) ->
    receive
        {accepted, Cancel} ->
            loop(State#{held := [Cancel | maps:get(held, State)]});
        {tcp, Client, Bytes} ->
            ok = gen_tcp:send(Server, Bytes),
            loop(note(State, main_bytes));
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

note(State = #{recording := true, events := Events}, Event) ->
    State#{events := [Event | Events]};
note(State, _Event) ->
    State.

%% Each held cancel gets its own upstream socket; the gate relays the
%% cancel's bytes and the server's close back to the driver.
release_held(State = #{held := Held, server_port := ServerPort}) ->
    lists:foreach(fun(Cancel) -> relay(Cancel, ServerPort) end, Held),
    note(State#{held := []}, cancel_passed).

relay(Cancel, ServerPort) ->
    Owner = self(),
    Pid = spawn(fun() -> relay_loop(Cancel, ServerPort) end),
    ok = gen_tcp:controlling_process(Cancel, Pid),
    Pid ! {go, Owner}.

relay_loop(Cancel, ServerPort) ->
    receive {go, _Owner} -> ok end,
    {ok, Server} = gen_tcp:connect("localhost", ServerPort, [binary, {active, true}]),
    ok = inet:setopts(Cancel, [{active, true}]),
    relay_bytes(Cancel, Server).

relay_bytes(Cancel, Server) ->
    receive
        {tcp, Cancel, Bytes} -> gen_tcp:send(Server, Bytes), relay_bytes(Cancel, Server);
        {tcp, Server, Bytes} -> gen_tcp:send(Cancel, Bytes), relay_bytes(Cancel, Server);
        {tcp_closed, Server} -> gen_tcp:close(Cancel);
        {tcp_closed, Cancel} -> gen_tcp:close(Server)
    end.

forward_cancel(_Other, _Bytes, _State) ->
    ok.
