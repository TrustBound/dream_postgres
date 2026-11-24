-module(dream_postgres_recorder_ffi).

%% The Erlang side of dream_postgres/recorder and dream_postgres/recording:
%% it turns the terms that the driver gives into `RecordedValue` values and
%% back, and reads and writes the recording files.

-export([to_recorded/1, from_recorded/1, to_dynamic/1, is_json_null/1,
         bits_to_hex/1, hex_to_bits/2, write_file/2, read_file/1]).

%% Turns a term of the driver into a `RecordedValue`. The constructors of
%% that Gleam type are `null`, `{boolean, B}`, `{integer, I}`, `{real, F}`,
%% `{text, S}`, `{bytes, B}`, `{array, L}`, `{tuple, L}`, `{map, Pairs}` and
%% `{atom, Name}`. A binary that is valid UTF-8 is text, any other binary or
%% bit string is bytes. Both are the same kind of term to the driver, so
%% both give back the same term.
to_recorded(null) -> {ok, null};
to_recorded(true) -> {ok, {boolean, true}};
to_recorded(false) -> {ok, {boolean, false}};
to_recorded(Atom) when is_atom(Atom) -> {ok, {atom, atom_to_binary(Atom, utf8)}};
to_recorded(Integer) when is_integer(Integer) -> {ok, {integer, Integer}};
to_recorded(Float) when is_float(Float) -> {ok, {real, Float}};
to_recorded(Binary) when is_binary(Binary) ->
    case unicode:characters_to_binary(Binary) of
        Binary -> {ok, {text, Binary}};
        _ -> {ok, {bytes, Binary}}
    end;
to_recorded(Bits) when is_bitstring(Bits) -> {ok, {bytes, Bits}};
to_recorded(List) when is_list(List) -> all(List, array);
to_recorded(Tuple) when is_tuple(Tuple) -> all(tuple_to_list(Tuple), tuple);
to_recorded(Map) when is_map(Map) ->
    case all(lists:sort(maps:to_list(Map)), array) of
        {ok, {array, Pairs}} -> {ok, {map, [{K, V} || {tuple, [K, V]} <- Pairs]}};
        Error -> Error
    end;
to_recorded(Other) ->
    {error, iolist_to_binary(io_lib:format("~p", [Other]))}.

all(Terms, Tag) -> all(Terms, Tag, []).

all([], Tag, Done) -> {ok, {Tag, lists:reverse(Done)}};
all([Term | Rest], Tag, Done) ->
    case to_recorded(Term) of
        {ok, Recorded} -> all(Rest, Tag, [Recorded | Done]);
        Error -> Error
    end.

%% Turns a `RecordedValue` back into the term of the driver.
from_recorded(null) -> null;
from_recorded({boolean, Boolean}) -> Boolean;
from_recorded({integer, Integer}) -> Integer;
from_recorded({real, Float}) -> Float;
from_recorded({text, Text}) -> Text;
from_recorded({bytes, Bytes}) -> Bytes;
from_recorded({array, List}) -> [from_recorded(Value) || Value <- List];
from_recorded({tuple, List}) -> list_to_tuple([from_recorded(Value) || Value <- List]);
from_recorded({map, Pairs}) ->
    maps:from_list([{from_recorded(K), from_recorded(V)} || {K, V} <- Pairs]);
from_recorded({atom, Name}) -> binary_to_atom(Name, utf8).

%% A `dream_postgres_client.Value` is the term that the driver sends.
to_dynamic(Value) -> Value.

%% `json:decode/1` gives the atom `null` for a JSON null.
is_json_null(null) -> true;
is_json_null(_) -> false.

%% A bit string whose size is not a multiple of 8, as its size in bits and
%% the base 16 text of its bytes, with zero bits at the end of the last byte.
bits_to_hex(Bits) ->
    Size = bit_size(Bits),
    Padding = (8 - Size rem 8) rem 8,
    {Size, binary:encode_hex(<<Bits/bitstring, 0:Padding>>)}.

%% The first `Size` bits of the bytes that `Hex` gives.
hex_to_bits(Size, Hex) ->
    try binary:decode_hex(Hex) of
        Bytes when bit_size(Bytes) >= Size ->
            <<Bits:Size/bitstring, _/bitstring>> = Bytes,
            {ok, Bits};
        _ ->
            {error, nil}
    catch
        error:badarg -> {error, nil}
    end.

%% Writes the file in one step: first to a temporary file next to it, then
%% a rename. A reader never sees half a file. The folder is made when it
%% does not exist. An error is the text of the file system error, such as
%% `permission denied`, without the path.
write_file(Path, Content) ->
    Temporary = <<Path/binary, ".tmp">>,
    Result = case filelib:ensure_path(filename:dirname(Path)) of
        ok ->
            case file:write_file(Temporary, Content) of
                ok -> file:rename(Temporary, Path);
                Error -> Error
            end;
        Error ->
            Error
    end,
    case Result of
        ok -> {ok, nil};
        {error, Reason} -> {error, unicode:characters_to_binary(file:format_error(Reason))}
    end.

read_file(Path) ->
    case file:read_file(Path) of
        {ok, Content} -> {ok, Content};
        {error, Reason} -> {error, describe(Path, Reason)}
    end.

describe(Path, Reason) ->
    iolist_to_binary(io_lib:format("~ts: ~ts", [Path, file:format_error(Reason)])).
