-module(driver_listener_test_ffi).
-export([connection_pid/1, stop_connection/1, stop_connection_process/1]).

%% The connection process of a listener, read from the state of the
%% listener's actor. A Listener is the record {listener, Subject, Pid}, and
%% the state is {state, Connection, Starter, Deadline, Subscriptions}, with
%% Connection the record {connection, Subject, Pid, ReplyMargin, SpanTarget}.
connection_pid({listener, _Subject, Pid}) ->
    state_connection(sys:get_state(Pid)).

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
