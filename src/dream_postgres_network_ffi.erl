-module(dream_postgres_network_ffi).
-export([parse_address/1]).

%% The address of a text, as IpAddress: {ipv4, A, B, C, D} or
%% {ipv6, A, B, C, D, E, F, G, H}. OTP's strict parser takes no zone
%% index, no leading zeros in IPv4 parts and no short IPv4 forms.
parse_address(Text) ->
    case inet:parse_strict_address(unicode:characters_to_list(Text)) of
        {ok, {A, B, C, D}} -> {ok, {ipv4, A, B, C, D}};
        {ok, {A, B, C, D, E, F, G, H}} -> {ok, {ipv6, A, B, C, D, E, F, G, H}};
        {error, _} -> {error, nil}
    end.
