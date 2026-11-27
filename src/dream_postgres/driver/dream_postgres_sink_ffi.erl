-module(dream_postgres_sink_ffi).
-export([new_drop_flag/0, deliver/4]).

%% The delivery of dream_postgres/driver/sink: the one place where the
%% driver catches a crash.
%%
%% Each sink has one drop flag, an atomics array of one, which every copy
%% of the sink shares, in every process that holds one. A pool gives copies
%% of its sinks to each connection: the flag drops a crashed map for each
%% of them at once, and for each connection that starts later.

new_drop_flag() ->
    atomics:new(1, []).

%% Map is the function of the sink's user. A crash of it, of any class,
%% sets the flag and gives map_failed, and the caller drops the sink, so a
%% bad map never stops a pool, a connection or a listener. A sink whose
%% flag is set calls nothing and gives map_failed. Send runs after the
%% try, in the "of" part, which the catch does not cover: only the map is
%% caught.
%%
%% The atoms are the constructors of the Gleam type Delivery.
deliver(Dropped, Map, Send, Event) ->
    case atomics:get(Dropped, 1) of
        1 -> map_failed;
        0 -> deliver_live(Dropped, Map, Send, Event)
    end.

deliver_live(Dropped, Map, Send, Event) ->
    try Map(Event) of
        Message ->
            Send(Message),
            delivered
    catch
        _Class:_Reason ->
            atomics:put(Dropped, 1, 1),
            map_failed
    end.
