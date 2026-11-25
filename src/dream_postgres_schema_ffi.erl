-module(dream_postgres_schema_ffi).
-export([sha256_hex/1]).

%% The SHA-256 hash of a UTF-8 binary, as 64 lowercase hexadecimal digits.
sha256_hex(Text) ->
    binary:encode_hex(crypto:hash(sha256, Text), lowercase).
