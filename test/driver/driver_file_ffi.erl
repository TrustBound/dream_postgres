-module(driver_file_ffi).
-export([read_recording/1, read_certificate/1, read_pem_certificate/1]).

%% Reads a file of bytes that a real server sent, from test/driver/recorded.
read_recording(Name) ->
    read(filename:join(["test", "driver", "recorded", Name])).

%% Reads a test certificate, in DER, from test/fixtures/channel_binding.
read_certificate(Name) ->
    read(filename:join(["test", "fixtures", "channel_binding", Name])).

read(Path) ->
    case file:read_file(Path) of
        {ok, Bytes} -> {ok, Bytes};
        {error, Reason} -> {error, atom_to_binary(Reason)}
    end.

%% The DER bytes of the first certificate of a PEM file, or an error text
%% when the file cannot be read or holds no certificate.
read_pem_certificate(Path) ->
    case read(Path) of
        {ok, Pem} -> first_certificate(public_key:pem_decode(Pem));
        {error, Reason} -> {error, Reason}
    end.

first_certificate([{'Certificate', Der, not_encrypted} | _]) -> {ok, Der};
first_certificate(_Entries) -> {error, <<"no certificate in the file">>}.
