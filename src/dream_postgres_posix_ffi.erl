-module(dream_postgres_posix_ffi).
-export([from_reason/1, name/1]).

%% The Posix value of an atom of OTP: the atom itself when the Gleam type
%% lists it (a variant is its atom), and {unlisted, Name} for any other
%% atom, such as errno_N or a name of the C library.
from_reason(Reason) when is_atom(Reason) ->
    case lists:member(Reason, 'dream_postgres@posix':posix_codes()) of
        true -> {ok, Reason};
        false -> {ok, {unlisted, atom_to_binary(Reason)}}
    end;
from_reason(Reason) ->
    {error, {not_an_atom, Reason}}.

%% The name of a Posix value: the name of its atom, or the name that
%% Unlisted holds.
name({unlisted, Name}) -> Name;
name(Atom) when is_atom(Atom) -> atom_to_binary(Atom).
