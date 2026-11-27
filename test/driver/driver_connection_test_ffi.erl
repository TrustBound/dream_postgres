-module(driver_connection_test_ffi).
-export([pid_of/1]).

%% The process of a connection, so a test can send it a message that is
%% not about its socket. A Connection is the record {connection, Subject, Pid}.
pid_of({connection, _Subject, Pid}) -> Pid.
