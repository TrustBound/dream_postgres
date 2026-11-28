-module(dream_postgres_normalize_ffi).
-export([stored/1, store/2]).

%% The value that `store` kept under the key in the process that runs,
%% as an option.
stored(Key) ->
    case erlang:get({dream_postgres_normalize, Key}) of
        undefined -> none;
        Value -> {some, Value}
    end.

%% Keeps the value under the key in the process that runs.
store(Key, Value) ->
    erlang:put({dream_postgres_normalize, Key}, Value),
    nil.
