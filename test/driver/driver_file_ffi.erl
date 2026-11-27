-module(driver_file_ffi).
-export([read_recording/1, read_certificate/1]).

%% Reads a file of bytes that a real server sent, from test/driver/recorded.
read_recording(Name) ->
    Path = filename:join(["test", "driver", "recorded", Name]),
    case file:read_file(Path) of
        {ok, Bytes} -> {ok, Bytes};
        {error, Reason} -> {error, atom_to_binary(Reason)}
    end.

%% The DER bytes of the first certificate of a PEM file, or an error text
%% when the file cannot be read or holds no certificate.
read_certificate(Path) ->
    case file:read_file(Path) of
        {ok, Pem} -> first_certificate(public_key:pem_decode(Pem));
        {error, Reason} -> {error, atom_to_binary(Reason)}
    end.

first_certificate([{'Certificate', Der, not_encrypted} | _]) -> {ok, Der};
first_certificate(_Entries) -> {error, <<"no certificate in the file">>}.
