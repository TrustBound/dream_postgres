-module(dream_postgres_connection_ffi).
-export([call/3, reply/2]).

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

reply(Alias, Value) ->
    Alias ! {Alias, Value},
    nil.
