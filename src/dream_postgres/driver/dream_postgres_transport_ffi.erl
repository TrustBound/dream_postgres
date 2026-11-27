-module(dream_postgres_transport_ffi).
-export([tcp_connect/3, tcp_send/2, tcp_receive/2, tcp_close/1,
         tls_connect/5, tls_send/2, tls_receive/2, tls_close/1,
         peer_certificate/1, read_authority_file/1, reason_name/1]).

%% The socket calls of dream_postgres/driver/transport. Each function does
%% one OTP call and gives a Gleam result: {ok, Value} or {error, Reason},
%% where Reason is an atom that transport.gleam turns into a typed error.

%% Opens a TCP connection. show_econnreset gives a reset by the peer as
%% econnreset, not as closed.
tcp_connect(Host, Port, Timeout) ->
    Options = [binary, {active, false}, {packet, raw}, {nodelay, true},
               {keepalive, true}, {show_econnreset, true}],
    gen_tcp:connect(binary_to_list(Host), Port, Options, Timeout).

tcp_send(Socket, Bytes) ->
    nil_result(gen_tcp:send(Socket, Bytes)).

tcp_receive(Socket, Timeout) ->
    gen_tcp:recv(Socket, 0, Timeout).

tcp_close(Socket) ->
    gen_tcp:close(Socket),
    nil.

%% Starts TLS on a connected TCP socket. Check is skip_check, authority or
%% authority_and_host. Authorities is system or {certificates, [Der]}. ServerName is the host as the caller gave it.
%%
%% The certificate checks run in a verify fun, which sends the reason of a
%% failed check to this process before the handshake fails, so the error
%% names the reason and not only the TLS alert.
tls_connect(Socket, Check, Authorities, ServerName, Timeout) ->
    Reference = make_ref(),
    Options = tls_options(Check, Authorities, binary_to_list(ServerName),
                          {self(), Reference, Check}),
    tls_result(ssl:connect(Socket, Options, Timeout), Reference).

tls_options(skip_check, _Authorities, _ServerName, _State) ->
    common_tls_options() ++ [{verify, verify_none}];
tls_options(_Check, Authorities, ServerName, State) ->
    common_tls_options() ++
        [{verify, verify_peer},
         authority_option(Authorities),
         {server_name_indication, ServerName},
         {verify_fun, {fun verify_certificate/3, State}}].

%% ALPN "postgresql" is what PostgreSQL 17 and later need for direct TLS.
%% The TLS alerts are errors of the connect; the ssl application must not
%% log them too.
common_tls_options() ->
    [{versions, ['tlsv1.3', 'tlsv1.2']},
     {alpn_advertised_protocols, [<<"postgresql">>]},
     {log_level, none}].

authority_option(system) -> {cacerts, public_key:cacerts_get()};
authority_option({certificates, Certificates}) -> {cacerts, Certificates}.

%% Each failed check goes to failed_check/3. An extension that the ssl
%% application does not know is for its own default check (unknown).
verify_certificate(_Certificate, {bad_cert, Reason}, State) ->
    failed_check(reason_name(Reason), State);
verify_certificate(_Certificate, {extension, _}, State) ->
    {unknown, State};
verify_certificate(_Certificate, _ValidOrValidPeer, State) ->
    {valid, State}.

%% verify-ca (authority) checks the chain only, so a host name that does
%% not match is no failure for it.
failed_check(hostname_check_failed, {_, _, authority} = State) ->
    {valid, State};
failed_check(Name, {Caller, Reference, _}) ->
    Caller ! {Reference, Name},
    {fail, Name}.

%% The name of a reason: the atom itself, or the first element of a tuple
%% such as {revoked, keyCompromise}.
reason_name(Reason) when is_atom(Reason) -> Reason;
reason_name(Reason) -> element(1, Reason).

tls_result({ok, TlsSocket}, _Reference) ->
    {ok, TlsSocket};
tls_result({error, Reason}, Reference) ->
    receive
        {Reference, CheckReason} -> {error, CheckReason}
    after 0 ->
        {error, alert_name(Reason)}
    end.

alert_name({tls_alert, {Alert, _Description}}) -> Alert;
alert_name(Reason) -> reason_name(Reason).

tls_send(Socket, Bytes) ->
    nil_result(ssl:send(Socket, Bytes)).

tls_receive(Socket, Timeout) ->
    ssl:recv(Socket, 0, Timeout).

tls_close(Socket) ->
    ssl:close(Socket),
    nil.

%% The DER bytes of the server's certificate, for channel binding.
peer_certificate(Socket) ->
    ssl:peercert(Socket).

%% Reads a PEM file of CA certificates and gives their DER bytes, so the
%% ssl application gets the caller's list and never a file it reads later.
read_authority_file(Path) ->
    case file:read_file(Path) of
        {ok, Pem} -> {ok, [Der || {'Certificate', Der, not_encrypted} <- public_key:pem_decode(Pem)]};
        {error, Reason} -> {error, Reason}
    end.

nil_result(ok) -> {ok, nil};
nil_result({error, Reason}) -> {error, Reason}.
