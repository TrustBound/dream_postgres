-module(driver_copy_test_ffi).
-export([memory_of/1, send_stray_down/1]).

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
