-module(driver_file_ffi).
-export([read_recording/1, read_certificate/1]).

%% Reads a file of bytes that a real server sent, from test/driver/recorded.
read_recording(Name) ->
    Path = filename:join(["test", "driver", "recorded", Name]),
    case file:read_file(Path) of
        {ok, Bytes} -> {ok, Bytes};
        {error, Reason} -> {error, atom_to_binary(Reason)}
    end.

%% The DER bytes of the first certificate of a PEM file.
read_certificate(Path) ->
    {ok, Pem} = file:read_file(Path),
    [{'Certificate', Der, not_encrypted} | _] = public_key:pem_decode(Pem),
    Der.
