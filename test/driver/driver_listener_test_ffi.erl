-module(driver_listener_test_ffi).
-export([connection_pid/1, stop_connection/1, stop_connection_process/1,
         restart_first_child/1, first_child_restart/1]).

%% The connection process of a listener, read from the state of the
%% listener's actor. A Listener is the record {listener, Subject}, with
%% the subject {subject, Pid, Tag}, or {named_subject, Name} for a
%% listener under a name. The state is {state, Connection, Starter,
%% Deadline, Subscriptions}, with Connection the record
%% {connection, Subject, Pid, ReplyMargin, SpanTarget}.
connection_pid({listener, Subject}) ->
    state_connection(sys:get_state(owner_of(Subject))).

owner_of({subject, Pid, _Tag}) -> Pid;
owner_of({named_subject, Name}) -> erlang:whereis(Name).

state_connection({state, {connection, _Subject, Pid, _Margin, _Target}, _Starter,
                  _Deadline, _Subscriptions}) ->
    Pid.

%% Sends the connection process of the listener an exit signal, as a
%% supervisor that ends it does, and waits until it is gone. The process
%% traps exits and stops with the reason normal, so the linked listener
%% stays.
stop_connection(Listener) ->
    stop_connection_process(connection_pid(Listener)).

%% As stop_connection, for a connection process read before: the listener
%% answers no sys:get_state while it waits for its connection.
stop_connection_process(Pid) ->
    Monitor = erlang:monitor(process, Pid),
    exit(Pid, shutdown),
    receive
        {'DOWN', Monitor, process, Pid, _Reason} -> nil
    end.

%% Stops the first child of the supervisor and starts it again, as a
%% supervisor does after the child failed, and gives {ok, nil} once the new
%% child runs, or {error, Text}.
restart_first_child(Supervisor) ->
    case supervisor:terminate_child(Supervisor, 0) of
        ok -> restarted(supervisor:restart_child(Supervisor, 0));
        {error, Reason} -> {error, unicode:characters_to_binary(io_lib:format("~p", [Reason]))}
    end.

restarted({ok, _Pid}) -> {ok, nil};
restarted({ok, _Pid, _Info}) -> {ok, nil};
restarted({error, Reason}) ->
    {error, unicode:characters_to_binary(io_lib:format("~p", [Reason]))}.

%% The restart type of the first child of the supervisor, as a text, for
%% example <<"transient">>.
first_child_restart(Supervisor) ->
    case supervisor:get_childspec(Supervisor, 0) of
        {ok, #{restart := Restart}} -> {ok, atom_to_binary(Restart)};
        {error, Reason} ->
            {error, unicode:characters_to_binary(io_lib:format("~p", [Reason]))}
    end.
