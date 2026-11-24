-module(recorder_ffi).
-export([delete_directory/1, make_read_only/1, make_writable/1, is_registered/1, describe/1, unsafe_value/1, write_file/2]).

%% Deletes a directory and everything in it. A directory that does not
%% exist is fine.
delete_directory(Path) ->
    _ = file:del_dir_r(Path),
    nil.

%% Makes a file or a directory read-only, so that the recorder cannot
%% write in it.
make_read_only(Path) ->
    ok = file:change_mode(Path, 8#555),
    nil.

%% True when a process is registered under the name.
is_registered(Name) ->
    whereis(Name) =/= undefined.

%% Makes a directory writable again, so that it can be deleted.
make_writable(Path) ->
    ok = file:change_mode(Path, 8#755),
    nil.

%% The text that the recorder writes for a term it cannot record.
describe(Term) ->
    iolist_to_binary(io_lib:format("~p", [Term])).

%% Any term as a query parameter, for a parameter the recorder cannot
%% record.
unsafe_value(Term) -> Term.

write_file(Path, Content) ->
    ok = file:write_file(Path, Content),
    nil.
