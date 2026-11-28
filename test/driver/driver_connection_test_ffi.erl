-module(driver_connection_test_ffi).
-export([pid_of/1, send_stray_message/1, unique_lock_key/0]).

%% The process of a connection, so a test can send it a message that is
%% not about its socket. A Connection is the record
%% {connection, Subject, Pid, ReplyMargin, SpanTarget}.
pid_of({connection, _Subject, Pid, _ReplyMargin, _SpanTarget}) -> Pid.

%% Sends the connection process a message that is not about its socket.
send_stray_message(Connection) ->
    pid_of(Connection) ! <<"not a socket message">>,
    nil.

%% An advisory lock key that no other test of this run uses. The keys start
%% at 100000, far from the fixed keys that some tests use.
unique_lock_key() -> 100000 + erlang:unique_integer([positive]).
