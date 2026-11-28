-module(dream_postgres_driver_ffi).
-export([certificate_hash_identifier/1, monotonic_milliseconds/0]).

-include_lib("public_key/include/public_key.hrl").

%% Gives the object identifier that names the hash of a certificate's
%% signature, as a list of integers, from the certificate's DER bytes.
%%
%% For most signature algorithms the algorithm's own identifier names the
%% hash, for example sha256WithRSAEncryption. RSASSA-PSS names its hash in
%% its parameters (RFC 4055 section 3.1), so for it the identifier is the
%% one of that hash. Bytes that are not a certificate give {error, nil}.
certificate_hash_identifier(Certificate) ->
    try public_key:pkix_decode_cert(Certificate, otp) of
        #'OTPCertificate'{signatureAlgorithm = Algorithm} ->
            {ok, tuple_to_list(hash_identifier(Algorithm))}
    catch
        _:_ -> {error, nil}
    end.

hash_identifier(#'SignatureAlgorithm'{
    algorithm = ?'id-RSASSA-PSS',
    parameters = #'RSASSA-PSS-params'{
        hashAlgorithm = #'HashAlgorithm'{algorithm = Hash}
    }
}) ->
    Hash;
hash_identifier(#'SignatureAlgorithm'{algorithm = Algorithm}) ->
    Algorithm.

%% The time of the monotonic clock of the VM, in milliseconds. A change of
%% the system time does not move it.
monotonic_milliseconds() ->
    erlang:monotonic_time(millisecond).
