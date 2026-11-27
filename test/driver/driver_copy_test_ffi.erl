-module(driver_copy_test_ffi).
-export([memory_of/1, send_stray_down/1, wait_for_message/3,
         wait_for_mailbox_length/3, wait_for_reset/2]).

%% What a process holds now, for the COPY memory tests: its own memory
%% (heap, stack and mailbox) plus the bytes of every binary that it
%% references, which live outside its heap, and the length of its mailbox.
memory_of(Pid) ->
    {memory, Memory} = erlang:process_info(Pid, memory),
    {binary, Binaries} = erlang:process_info(Pid, binary),
    {message_queue_len, Queue} = erlang:process_info(Pid, message_queue_len),
    {Memory + lists:sum([Size || {_Id, Size, _Count} <- Binaries]), Queue}.

%% Sends the process a DOWN message of a monitor that it never made.
send_stray_down(Pid) ->
    Pid ! {'DOWN', make_ref(), process, self(), normal},
    nil.

%% Waits until a message with one of Tags waits in the mailbox of Pid:
%% a tuple whose first element is that atom, such as `tcp`, or a message
%% of a subject, {Reference, Message}, whose Message is such a tuple, such
%% as `request`. It asks again each time, at most Attempts times: no
%% sleep. Gives whether it came.
wait_for_message(Pid, Tags, Attempts) ->
    Atoms = [binary_to_atom(Tag) || Tag <- Tags],
    wait_for(fun() -> has_message(Pid, Atoms) end, Attempts).

has_message(Pid, Atoms) ->
    {messages, Messages} = erlang:process_info(Pid, messages),
    lists:any(fun(Message) -> is_tagged(Message, Atoms) end, Messages).

is_tagged({Reference, Message}, Atoms) when is_reference(Reference) ->
    is_tagged(Message, Atoms);
is_tagged(Message, Atoms) when is_tuple(Message), tuple_size(Message) > 0 ->
    lists:member(element(1, Message), Atoms);
is_tagged(_Message, _Atoms) ->
    false.

%% Waits until at least Length messages wait in the mailbox of Pid. It
%% asks again each time, at most Attempts times: no sleep. Gives whether
%% they came.
wait_for_mailbox_length(Pid, Length, Attempts) ->
    wait_for(fun() -> mailbox_length(Pid) >= Length end, Attempts).

mailbox_length(Pid) ->
    {message_queue_len, MessageCount} =
        erlang:process_info(Pid, message_queue_len),
    MessageCount.

%% Waits until the TCP socket of Pid has no peer any more: the reset of
%% the peer reached it. Gives whether it did.
wait_for_reset(Pid, Attempts) ->
    [Socket | _] = [Port || Port <- element(2, erlang:process_info(Pid, links)),
                            is_port(Port),
                            erlang:port_info(Port, name) =:= {name, "tcp_inet"}],
    wait_for(fun() -> element(1, inet:peername(Socket)) =:= error end, Attempts).

wait_for(_Check, 0) -> false;
wait_for(Check, Attempts) ->
    case Check() of
        true -> true;
        false -> erlang:yield(), wait_for(Check, Attempts - 1)
    end.
