-module(pool_test_ffi).
-export([supervisor_of/1, members_of/1]).

%% The processes inside a pool, so a test can make one of them exit as a
%% bug or an operator would. A Pool is the record {pool, Subject}, with the
%% subject of its manager: {subject, Pid, Tag}, or {named_subject, Name}
%% for a pool that started under a name. The manager links to its owner,
%% to its catalog and to the supervisor of its members, the only one of
%% them that proc_lib started as a supervisor.

supervisor_of(Pool) ->
    {links, Links} = erlang:process_info(manager_of(Pool), links),
    [Supervisor] = [Link || Link <- Links, is_supervisor(Link)],
    Supervisor.

members_of(Pool) ->
    [Member || {_Id, Member, _Type, _Modules} <- supervisor:which_children(supervisor_of(Pool))].

manager_of({pool, {subject, Manager, _Tag}}) -> Manager;
manager_of({pool, {named_subject, Name}}) -> erlang:whereis(Name).

is_supervisor(Pid) ->
    case proc_lib:initial_call(Pid) of
        {supervisor, _Module, _Arguments} -> true;
        _ -> false
    end.
