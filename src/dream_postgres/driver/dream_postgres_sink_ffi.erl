-module(dream_postgres_sink_ffi).
-export([deliver/3]).

%% The delivery of dream_postgres/driver/sink: the one place where the
%% driver catches a crash.
%%
%% Map is the function of the sink's user. A crash of it, of any class,
%% gives map_failed, and the caller drops the sink, so a bad map never
%% stops a pool, a connection or a listener. Send runs after the try, in
%% the "of" part, which the catch does not cover: only the map is caught.
%%
%% The atoms are the constructors of the Gleam type Delivery.
deliver(Map, Send, Event) ->
    try Map(Event) of
        Message ->
            Send(Message),
            delivered
    catch
        _Class:_Reason -> map_failed
    end.
