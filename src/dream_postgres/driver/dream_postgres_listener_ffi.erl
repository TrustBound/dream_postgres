-module(dream_postgres_listener_ffi).
-export([call/2, reply/2, deliver/2, request_of/1]).

%% A call to a process of a listener, its registry or its session, that
%% waits until the answer comes or the process is gone, with no timeout.
%%
%% The monitor is also an alias (OTP 24 and later): the process replies to
%% the alias, and the reply turns the alias and the monitor off. A process
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

%% Messages to the registry of a listener, sent to its process ID.
%%
%% A send to a pid never fails, also when the process is gone: the message
%% is dropped, and the caller's monitor tells it that the registry is gone.
%% A send to a registered name fails when no process has the name, which is
%% the case for a moment while a supervisor starts a named listener again.
%% So each sender looks the name up once, and sends to the pid.
%%
%% The tag is the listener module's own. The registry selects messages
%% with it as a record of one field.
deliver(Pid, Message) ->
    Pid ! {dream_postgres_listener_request, Message},
    nil.

request_of({dream_postgres_listener_request, Message}) -> Message.
