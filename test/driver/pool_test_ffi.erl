-module(pool_test_ffi).
-export([supervisor_of/1, members_of/1]).

%% The processes inside a pool, so a test can make one of them exit as a
%% bug or an operator would. A Pool is the record {pool, Subject}, with the
%% subject of its manager: {subject, Pid, Tag}, or {named_subject, Name}
%% for a pool that started under a name. The manager links to its owner,
%% to its catalog and to the supervisor of its members, the only one of
%% them that proc_lib started as a supervisor.
%%
%% Each function gives {ok, Value}, or {error, nil} when the pool has no
%% such process.

supervisor_of(Pool) ->
    only_supervisor(supervisors_of(manager_of(Pool))).

members_of(Pool) ->
    members_of_supervisor(supervisor_of(Pool)).

members_of_supervisor({ok, Supervisor}) ->
    {ok, [Member || {_Id, Member, _Type, _Modules} <- supervisor:which_children(Supervisor)]};
members_of_supervisor({error, nil}) ->
    {error, nil}.

supervisors_of(Manager) when is_pid(Manager) ->
    links_of(erlang:process_info(Manager, links));
supervisors_of(_NoManager) ->
    [].

links_of({links, Links}) -> [Link || Link <- Links, is_supervisor(Link)];
links_of(undefined) -> [].

only_supervisor([Supervisor]) -> {ok, Supervisor};
only_supervisor(_NoneOrMore) -> {error, nil}.

manager_of({pool, {subject, Manager, _Tag}}) -> Manager;
manager_of({pool, {named_subject, Name}}) -> erlang:whereis(Name).

is_supervisor(Pid) when is_pid(Pid) ->
    case proc_lib:initial_call(Pid) of
        {supervisor, _Module, _Arguments} -> true;
        _ -> false
    end;
is_supervisor(_Port) ->
    false.
