-module(dream_postgres_supervision_ffi).
-export([wait_for_restarts/1, stop_supervisor/1]).

%% Asks the supervisor for its children. The supervisor answers after it
%% has handled the exit signals that came before the call, so a child it
%% restarted is running again when this returns.
wait_for_restarts(Supervisor) ->
    _ = supervisor:which_children(Supervisor),
    nil.

%% Stops the supervisor and its children, and waits until it is gone. The
%% link to the caller goes first, so the caller lives on.
stop_supervisor(Supervisor) ->
    unlink(Supervisor),
    Monitor = erlang:monitor(process, Supervisor),
    exit(Supervisor, shutdown),
    receive
        {'DOWN', Monitor, process, Supervisor, _} -> nil
    end.
