-module(driver_listener_test_ffi).
-export([connection_pid/1, session_pid/1, stop_connection/1,
         stop_connection_process/1, restart_first_child/1,
         first_child_restart/1, registry_pid/1, suspend_process/1,
         resume_process/1, watch_received/1, wait_received/2]).

%% The connection process of a listener, read from the state of its
%% session.
connection_pid(Listener) ->
    session_connection(sys:get_state(session_pid(Listener))).

%% The session process of a listener, read from the state of its registry.
%% A Listener is the record {listener, Subject}, with the subject
%% {subject, Pid, Tag}, or {named_subject, Name} for a listener under a
%% name. The registry state is {registry_state, Session, Up, Starter,
%% Subscriptions}, with Session {some, {session_link, Subject, Pid,
%% Monitor}} once a session started.
session_pid({listener, Subject}) ->
    registry_session(sys:get_state(owner_of(Subject))).

owner_of({subject, Pid, _Tag}) -> Pid;
owner_of({named_subject, Name}) -> erlang:whereis(Name).

registry_session({registry_state, {some, {session_link, _Subject, Pid, _Monitor}},
                  _Up, _Starter, _Subscriptions}) ->
    Pid.

%% The session state is {session_state, Connection, Registry, Deadline},
%% with Connection the record {connection, Subject, Pid, ReplyMargin,
%% SpanTarget}.
session_connection({session_state, {connection, _Subject, Pid, _Margin, _Target},
                    _Registry, _Deadline}) ->
    Pid.

%% Sends the connection process of the listener an exit signal, as a
%% supervisor that ends it does, and waits until it is gone. The process
%% traps exits and stops with the reason normal, so the linked session
%% stays.
stop_connection(Listener) ->
    stop_connection_process(connection_pid(Listener)).

%% As stop_connection, for a connection process read before: the session
%% answers no sys:get_state while it waits for its connection, and the
%% registry none while it waits for its session.
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

%% The registry process of a listener.
registry_pid({listener, Subject}) ->
    owner_of(Subject).

%% Suspends a process, as sys does: it keeps each new message in its
%% mailbox, and handles none until resume_process.
suspend_process(Pid) ->
    sys:suspend(Pid),
    nil.

resume_process(Pid) ->
    sys:resume(Pid),
    nil.

%% Makes the calling process the tracer of each message that Pid
%% receives, so a test can wait for one without polling.
watch_received(Pid) ->
    erlang:trace(Pid, true, ['receive']),
    nil.

%% Waits until Pid received a message that holds a record whose tag is
%% Tag, or the atom Tag itself (a record of no field), at most 5 seconds. Gives {ok, nil}, or {error, Text}.
wait_received(Pid, Tag) ->
    receive
        {trace, Pid, 'receive', Message} ->
            case holds_tag(Message, Tag) of
                true -> {ok, nil};
                false -> wait_received(Pid, Tag)
            end
    after 5000 ->
        {error, <<"the process received no such message within 5 seconds">>}
    end.

holds_tag(Tag, Tag) ->
    true;
holds_tag(Message, Tag) when is_tuple(Message), tuple_size(Message) > 0 ->
    element(1, Message) =:= Tag orelse
        lists:any(fun(Part) -> holds_tag(Part, Tag) end, tl(tuple_to_list(Message)));
holds_tag(_Message, _Tag) ->
    false.
