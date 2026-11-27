-module(dream_postgres_recorder_ffi).
-export([write_file/2, read_file/1, is_file/1, claim/1]).

%% Writes the bytes to the file at Path, after it makes each directory
%% of the path that is missing.
write_file(Path, Bytes) ->
    posix_result(write_in_directory(filelib:ensure_path(filename:dirname(Path)), Path, Bytes)).

write_in_directory(ok, Path, Bytes) -> file:write_file(Path, Bytes);
write_in_directory(Error, _Path, _Bytes) -> Error.

%% Reads the bytes of the file at Path.
read_file(Path) ->
    posix_result(file:read_file(Path)).

%% Whether Path is a file that exists.
is_file(Path) ->
    filelib:is_regular(Path).

%% Takes the absolute form of Path for the calling process, until the
%% process ends: false when another process that runs holds it.
claim(Path) ->
    global:register_name({dream_postgres_recording, filename:absname(Path)}, self()) =:= yes.

%% The result with the Posix value of the reason of an error.
posix_result(ok) -> {ok, nil};
posix_result({ok, Bytes}) -> {ok, Bytes};
posix_result({error, Reason}) ->
    {ok, Posix} = dream_postgres_posix_ffi:from_reason(Reason),
    {error, Posix}.
