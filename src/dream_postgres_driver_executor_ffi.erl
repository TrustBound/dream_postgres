-module(dream_postgres_driver_executor_ffi).
-export([monotonic_milliseconds/0]).

%% The monotonic clock of the BEAM, in milliseconds. It never goes back,
%% so a deadline measured with it does not move when the wall clock does.
monotonic_milliseconds() ->
    erlang:monotonic_time(millisecond).
