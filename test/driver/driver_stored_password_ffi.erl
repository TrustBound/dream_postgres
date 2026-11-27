-module(driver_stored_password_ffi).
-export([store/2, stored/1]).

%% A password that a test keeps in the process dictionary of its process,
%% so a password function can read the value of that moment.

store(Key, Value) ->
    put(Key, Value),
    nil.

stored(Key) ->
    get(Key).
