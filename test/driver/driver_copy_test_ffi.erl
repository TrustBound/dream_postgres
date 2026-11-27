-module(driver_copy_test_ffi).
-export([memory_of/1, send_stray_down/1, wait_for_message/3,
         wait_for_mailbox_length/3, wait_for_reset/2]).

%% What a process holds now, for the COPY memory tests: its own memory
%% (heap, stack and mailbox) plus the bytes of every binary that it
%% references, which live outside its heap, and the length of its mailbox.
%% Gives {error, Reason} when the process is not alive.
memory_of(Pid) ->
    case erlang:process_info(Pid, [memory, binary, message_queue_len]) of
        [{memory, Memory}, {binary, Binaries}, {message_queue_len, Queue}] ->
            Referenced = lists:sum([Size || {_Id, Size, _Count} <- Binaries]),
            {ok, {Memory + Referenced, Queue}};
        undefined ->
            {error, not_alive(Pid)}
    end.

%% Sends the process a DOWN message of a monitor that it never made.
send_stray_down(Pid) ->
    Pid ! {'DOWN', make_ref(), process, self(), normal},
    nil.

%% Waits until a message with one of Tags waits in the mailbox of Pid:
%% a tuple whose first element is that atom, such as `tcp`, or a message
%% of a subject, {Reference, Message}, whose Message is such a tuple, such
%% as `request`. It asks again each time, at most Attempts times: no
%% sleep. Gives {ok, nil} when it came, else {error, Reason}.
wait_for_message(Pid, Tags, Attempts) ->
    Atoms = [binary_to_atom(Tag) || Tag <- Tags],
    GiveUp = iolist_to_binary(
        [<<"no message with the tag ">>, lists:join(<<" or ">>, Tags),
         <<" came">>]),
    wait_for(fun() -> has_message(Pid, Atoms) end, Attempts, GiveUp).

has_message(Pid, Atoms) ->
    case erlang:process_info(Pid, messages) of
        {messages, Messages} ->
            lists:any(fun(Message) -> is_tagged(Message, Atoms) end, Messages);
        undefined ->
            {error, not_alive(Pid)}
    end.

is_tagged({Reference, Message}, Atoms) when is_reference(Reference) ->
    is_tagged(Message, Atoms);
is_tagged(Message, Atoms) when is_tuple(Message), tuple_size(Message) > 0 ->
    lists:member(element(1, Message), Atoms);
is_tagged(_Message, _Atoms) ->
    false.

%% Waits until at least Length messages wait in the mailbox of Pid. It
%% asks again each time, at most Attempts times: no sleep. Gives {ok, nil}
%% when they came, else {error, Reason}.
wait_for_mailbox_length(Pid, Length, Attempts) ->
    GiveUp = iolist_to_binary(
        io_lib:format("the mailbox did not reach ~b messages", [Length])),
    wait_for(fun() -> has_mailbox_length(Pid, Length) end, Attempts, GiveUp).

has_mailbox_length(Pid, Length) ->
    case erlang:process_info(Pid, message_queue_len) of
        {message_queue_len, MessageCount} -> MessageCount >= Length;
        undefined -> {error, not_alive(Pid)}
    end.

%% Waits until the TCP socket of Pid has no peer any more: the reset of
%% the peer reached it. Gives {ok, nil} when it did, else {error, Reason},
%% also when Pid has no TCP socket.
wait_for_reset(Pid, Attempts) ->
    case tcp_sockets(Pid) of
        {ok, [Socket | _]} ->
            wait_for(fun() -> element(1, inet:peername(Socket)) =:= error end,
                     Attempts, <<"the reset did not reach the socket">>);
        {ok, []} ->
            {error, <<"the process has no TCP socket">>};
        {error, Reason} ->
            {error, Reason}
    end.

tcp_sockets(Pid) ->
    case erlang:process_info(Pid, links) of
        {links, Links} ->
            {ok, [Port || Port <- Links,
                          is_port(Port),
                          erlang:port_info(Port, name) =:= {name, "tcp_inet"}]};
        undefined ->
            {error, not_alive(Pid)}
    end.

%% Asks Check again, at most Attempts times, until it gives true. Gives
%% {error, GiveUp} when it never did, and the error of Check when it gave
%% one.
wait_for(_Check, 0, GiveUp) -> {error, GiveUp};
wait_for(Check, Attempts, GiveUp) ->
    case Check() of
        true -> {ok, nil};
        false -> erlang:yield(), wait_for(Check, Attempts - 1, GiveUp);
        {error, Reason} -> {error, Reason}
    end.

not_alive(Pid) ->
    iolist_to_binary(io_lib:format("the process ~p is not alive", [Pid])).
