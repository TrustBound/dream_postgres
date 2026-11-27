-module(dream_postgres_pool_ffi).
-export([deliver/2, request_of/1]).

%% Requests to the manager process of a pool, sent to its process ID.
%%
%% A send to a pid never fails, also when the process is gone: the message
%% is dropped, and the caller's monitor tells it that the pool is gone. A
%% send to a registered name fails when no process has the name, which is
%% the case for a moment while a supervisor starts a named pool again. So
%% the pool looks the name up once, and sends to the pid.
%%
%% The tag is the pool module's own. The manager selects messages with it
%% as a record of one field.

deliver(Pid, Message) ->
    Pid ! {dream_postgres_pool_request, Message},
    nil.

request_of({dream_postgres_pool_request, Message}) -> Message.
