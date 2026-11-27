-module(pool_test_ffi).
-export([supervisor_of/1, members_of/1]).

%% The processes inside a pool, so a test can make one of them exit as a
%% bug or an operator would. A Pool is the record {pool, Subject, Pid, Extra}.
%% The pool's manager links to its owner, the caller, and to the supervisor
%% of its members.

supervisor_of({pool, _Subject, Manager, _Extra}) ->
    {links, Links} = erlang:process_info(Manager, links),
    [Supervisor] = Links -- [self()],
    Supervisor.

members_of(Pool) ->
    [Member || {_Id, Member, _Type, _Modules} <- supervisor:which_children(supervisor_of(Pool))].
