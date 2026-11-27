-module(dream_postgres_transport_ffi).
-export([tcp_connect/4, tcp_send/2, tcp_receive/2, tcp_close/1,
         tls_connect/5, tls_send/2, tls_receive/2, tls_close/1,
         peer_certificate/1, read_authority_file/1, reason_name/1,
         tcp_receive_next/1, tls_receive_next/1, socket_event/2,
         tcp_received_bytes/1, tls_received_bytes/1]).

%% The socket calls of dream_postgres/driver/transport. Each function does
%% one OTP call and gives a Gleam result: {ok, Value} or {error, Reason},
%% where Reason is an atom that transport.gleam turns into a typed error.

%% Opens a TCP connection. show_econnreset gives a reset by the peer as
%% econnreset, not as closed. A send that waits longer than SendTimeout
%% fails with timeout and closes the socket (send_timeout_close).
tcp_connect(Host, Port, Timeout, SendTimeout) ->
    Options = [binary, {active, false}, {packet, raw}, {nodelay, true},
               {keepalive, true}, {show_econnreset, true},
               {send_timeout, SendTimeout}, {send_timeout_close, true}],
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

%% Asks for the next bytes as one message to this process: {tcp, ...} or
%% {ssl, ...}, then the socket goes back to passive mode.
tcp_receive_next(Socket) ->
    nil_result(inet:setopts(Socket, [{active, once}])).

tls_receive_next(Socket) ->
    nil_result(ssl:setopts(Socket, [{active, once}])).

%% Reads a message of the socket, for the socket given. A TCP and a TLS
%% socket send the same three messages with a different tag.
socket_event({Tag, Socket, Bytes}, Socket) when Tag =:= tcp; Tag =:= ssl ->
    {received, Bytes};
socket_event({Tag, Socket}, Socket) when Tag =:= tcp_closed; Tag =:= ssl_closed ->
    ended;
socket_event({Tag, Socket, Reason}, Socket) when Tag =:= tcp_error; Tag =:= ssl_error ->
    {failed, reason_name(Reason)};
socket_event(_Message, _Socket) ->
    other.

%% The bytes that the server sent before a write failed, for the owner of
%% the socket: the data messages of this socket that wait in the mailbox,
%% in order. It never waits: the receive has the timeout 0. Bytes that the
%% socket itself still holds are not read: the reset that fails a write
%% makes the system drop them.
tcp_received_bytes(Socket) -> iolist_to_binary(delivered(Socket, tcp, [])).

tls_received_bytes(Socket) -> iolist_to_binary(delivered(Socket, ssl, [])).

delivered(Socket, Tag, Bytes) ->
    receive
        {Tag, Socket, More} -> delivered(Socket, Tag, [Bytes, More])
    after 0 -> Bytes
    end.
