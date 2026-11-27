-module(dream_postgres_connection_ffi).
-export([call/3, call_until_answer/2, reply/2]).

%% A call to a connection process that waits until a deadline and never
%% leaves a late reply behind.
%%
%% The monitor is also an alias (OTP 24 and later): the connection process
%% replies to the alias, and when the deadline passes, the demonitor turns
%% the alias off, so a reply that comes later is dropped by the runtime and
%% never reaches the caller's mailbox. This is how gen_server:call works.
call(Pid, SendRequest, Timeout) ->
    Alias = erlang:monitor(process, Pid, [{alias, reply_demonitor}]),
    SendRequest(Alias),
    receive
        {Alias, Reply} -> {ok, Reply};
        {'DOWN', Alias, process, _Pid, _Reason} -> {error, call_process_down}
    after Timeout ->
        erlang:demonitor(Alias, [flush]),
        %% A reply that came between the timeout and the demonitor is late
        %% too: take it out of the mailbox, so it never stays there.
        receive {Alias, _Late} -> ok after 0 -> ok end,
        {error, call_deadline_passed}
    end.

%% A call that waits for the reply or the end of the process, with no
%% timer: for the first open, which the process answers by its own setup
%% deadline. gleam_erlang's process.call needs a timer, and a second timer
%% could end a start that the process completed. Its call_forever panics
%% when the process ends before it answers, where the start must give
%% SetupExited.
%%
%% The monitor is always released: the reply turns it off (reply_demonitor),
%% the 'DOWN' message ends it, and the runtime removes it when the caller
%% itself dies while it waits.
call_until_answer(Pid, SendRequest) ->
    Alias = erlang:monitor(process, Pid, [{alias, reply_demonitor}]),
    SendRequest(Alias),
    receive
        {Alias, Reply} -> {ok, Reply};
        {'DOWN', Alias, process, _Pid, _Reason} -> {error, call_process_down}
    end.

reply(Alias, Value) ->
    Alias ! {Alias, Value},
    nil.
