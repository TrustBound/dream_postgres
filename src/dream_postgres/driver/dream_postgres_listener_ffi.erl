-module(dream_postgres_listener_ffi).
-export([call/2, reply/2]).

%% A call to a listener process that waits until the answer comes or the
%% process is gone, with no timeout.
%%
%% The monitor is also an alias (OTP 24 and later): the listener replies to
%% the alias, and the reply turns the alias and the monitor off. A listener
%% that is gone, or that stops before it replies, gives the monitor's DOWN.
call(Pid, SendRequest) ->
    Alias = erlang:monitor(process, Pid, [{alias, reply_demonitor}]),
    SendRequest(Alias),
    receive
        {Alias, Reply} -> {ok, Reply};
        {'DOWN', Alias, process, _Pid, _Reason} -> {error, nil}
    end.

reply(Alias, Value) ->
    Alias ! {Alias, Value},
    nil.
