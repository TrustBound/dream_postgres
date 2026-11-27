//// Opens, reads, writes and closes the socket to a PostgreSQL server, over
//// TCP and TLS, with OTP's `gen_tcp` and `ssl`. This is the only driver
//// module that does IO.
////
//// The TLS settings follow libpq's `sslmode` and `sslnegotiation` (the
//// PostgreSQL documentation, "Database Connection Control Functions" and
//// "SSL Support"):
////
//// | libpq                         | `Tls`                                              |
//// |-------------------------------|----------------------------------------------------|
//// | `disable`                     | `NoTls`                                            |
//// | `prefer`                      | `PreferTls`                                        |
//// | `require`                     | `RequireTls(NoCertificateCheck, _)`                |
//// | `require` with a root CA file | `RequireTls(CheckAuthority(_), _)`                 |
//// | `verify-ca`                   | `RequireTls(CheckAuthority(_), _)`                 |
//// | `verify-full`                 | `RequireTls(CheckAuthorityAndHost(_), _)`          |
//// | `sslnegotiation=direct`       | `RequireTls(_, DirectNegotiation)`                 |
////
//// libpq allows direct negotiation only with `require` or stronger, so a
//// weaker mode cannot fall back to plain text. The `Tls` type cannot hold
//// direct negotiation with `PreferTls`. libpq's `allow` (plain text first,
//// then TLS) needs a failed login to decide, so it is not a transport
//// setting.
////
//// Every failure is a typed `TransportError`, and every failed setup step
//// closes the socket before it returns.
////
//// This module is internal to dream_postgres.

import dream_postgres/driver/deadline.{type Deadline, bounded_wait}
import dream_postgres/driver/decode.{decode_ssl_answer}
import dream_postgres/driver/encode.{ssl_request}
import dream_postgres/driver/message.{
  Decoded, EncryptionAccepted, EncryptionErrorResponse, EncryptionRefused,
  NeedMoreBytes, UnknownAnswer,
}
import gleam/bool.{guard}
import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}
import gleam/list.{all}
import gleam/option.{type Option, None}
import gleam/pair
import gleam/result.{map, map_error, try}
import gleam/string.{to_utf_codepoints, utf_codepoint_to_int}

/// A host and a port that a TCP connect can take. Make one with `address`.
pub opaque type Address {
  Address(host: String, port: Int)
}

/// Why a host or a port cannot be used.
pub type AddressError {
  /// The host is empty, or holds a space, a control character or a
  /// character outside ASCII. `gen_tcp:connect` exits for such a host.
  InvalidHost(host: String)
  /// The port is outside 1 to 65535.
  InvalidPort(port: Int)
}

/// Where the CA certificates for a certificate check come from. The
/// caller's file or list replaces the system list: the system list is read
/// only for `SystemAuthorities`.
pub type Authorities {
  /// The CA certificates of the operating system.
  SystemAuthorities
  /// A PEM file of CA certificates.
  AuthorityFile(path: String)
  /// CA certificates as DER bytes.
  AuthorityCertificates(certificates: List(BitArray))
}

/// What the client checks of the server's certificate.
pub type CertificateCheck {
  /// No check: libpq's `require`. The connection is encrypted, but any
  /// server can answer.
  NoCertificateCheck
  /// A trusted CA signed the certificate: libpq's `verify-ca`.
  CheckAuthority(authorities: Authorities)
  /// A trusted CA signed the certificate, and it names the host: libpq's
  /// `verify-full`.
  CheckAuthorityAndHost(authorities: Authorities)
}

/// How the client starts TLS.
pub type TlsNegotiation {
  /// Send an SSLRequest, and start TLS after the server answers `S`.
  PostgresNegotiation
  /// Start TLS at once, with ALPN `postgresql`. PostgreSQL 17 and later
  /// accept it.
  DirectNegotiation
}

/// Whether the connection uses TLS.
pub type Tls {
  /// Plain TCP: libpq's `disable`.
  NoTls
  /// TLS when the server accepts it, with no certificate check, and plain
  /// TCP when the server refuses it or TLS fails: libpq's `prefer`.
  PreferTls
  /// TLS, or no connection.
  RequireTls(check: CertificateCheck, negotiation: TlsNegotiation)
}

/// Everything that `connect` needs.
pub type TransportConfig {
  TransportConfig(
    address: Address,
    tls: Tls,
    /// The longest time for the TCP connect, the TLS answer and the TLS
    /// handshake, each. The deadline that `connect` gets can cut each of
    /// them shorter.
    connect_timeout_milliseconds: Int,
    /// The longest time that one send may wait while the server reads
    /// nothing. After it, the send fails with `SendTimedOut` and the
    /// socket closes, so a stuck server never blocks its owner.
    send_timeout_milliseconds: Int,
  )
}

/// Why a TLS handshake failed.
pub type TlsFailure {
  /// The certificate does not name the host.
  HostNameMismatch
  /// No trusted CA signed the certificate.
  UnknownAuthority
  /// The certificate has expired.
  CertificateExpired
  /// The CA file could not be read: the reason is the OS error, for
  /// example `enoent`.
  AuthorityFileUnreadable(path: String, reason: String)
  /// The CA file holds no certificate.
  AuthorityFileEmpty(path: String)
  /// Any other failure: the name of the TLS alert or of the check, for
  /// example `handshake_failure`.
  OtherTlsFailure(reason: String)
}

/// Why the transport failed.
pub type TransportError {
  /// Nothing listens on the port.
  ConnectRefused
  /// The TCP connect took longer than the timeout.
  ConnectTimedOut
  /// The host name has no address.
  DnsLookupFailed(host: String)
  /// The TLS handshake failed.
  TlsFailed(reason: TlsFailure)
  /// The server answered `N` to the SSLRequest, and the settings require
  /// TLS.
  ServerRefusedTls
  /// The server answered the SSLRequest with an ErrorResponse. Its text is
  /// not kept: the server is not yet authenticated (CVE-2024-10977).
  TlsRequestAnsweredWithError
  /// The answer to the SSLRequest was not `S`, `N` or `E`.
  UnexpectedTlsAnswer(answer_byte: Int)
  /// The server sent bytes after its `S` and before the TLS handshake.
  /// They did not come over TLS, so the connection is refused
  /// (CVE-2021-23222).
  BytesBeforeTls
  /// The server closed the connection.
  SocketClosed
  /// The connection was reset, for example by a proxy or a firewall.
  ConnectionReset
  /// No bytes came within the receive timeout.
  ReceiveTimedOut
  /// The server read nothing for the send timeout. The socket is closed.
  SendTimedOut
  /// Any other OS error: its name, for example `ehostunreach`.
  Unlisted(reason: String)
}

/// An open connection, plain or over TLS.
pub opaque type Connection {
  PlainConnection(socket: TcpSocket)
  TlsConnection(socket: TlsSocket)
}

type TcpSocket

type TlsSocket

/// What the FFI checks of the certificate.
type PeerCheck {
  SkipCheck
  Authority
  AuthorityAndHost
}

/// The answer to an SSLRequest that the connect goes on with.
type TlsAnswer {
  TlsAccepted
  TlsRefused
  TlsAnsweredWithError
}

/// A socket message as the FFI reads it.
type FfiSocketEvent {
  Received(BitArray)
  Ended
  Failed(Atom)
  Other
}

/// What a message to the owner process says about its connection.
pub type SocketEvent {
  /// Bytes from the server.
  BytesReceived(bytes: BitArray)
  /// The server or the network closed the connection.
  SocketEnded
  /// The socket failed, for example with a reset.
  SocketFailed(error: TransportError)
  /// The message is not about this connection: another socket's, or no
  /// socket's.
  NotThisSocket
}

/// The CA list as the FFI takes it.
type AuthorityList {
  System
  Certificates(List(BitArray))
}

@external(erlang, "dream_postgres_transport_ffi", "tcp_connect")
fn tcp_connect(
  host: String,
  port: Int,
  timeout: Int,
  send_timeout: Int,
) -> Result(TcpSocket, Atom)

@external(erlang, "dream_postgres_transport_ffi", "tcp_send")
fn tcp_send(socket: TcpSocket, bytes: BitArray) -> Result(Nil, Atom)

@external(erlang, "dream_postgres_transport_ffi", "tcp_receive")
fn tcp_receive(socket: TcpSocket, timeout: Int) -> Result(BitArray, Atom)

@external(erlang, "dream_postgres_transport_ffi", "tcp_close")
fn tcp_close(socket: TcpSocket) -> Nil

@external(erlang, "dream_postgres_transport_ffi", "tls_connect")
fn tls_connect(
  socket: TcpSocket,
  check: PeerCheck,
  authorities: AuthorityList,
  server_name: String,
  timeout: Int,
) -> Result(TlsSocket, Atom)

@external(erlang, "dream_postgres_transport_ffi", "tls_send")
fn tls_send(socket: TlsSocket, bytes: BitArray) -> Result(Nil, Atom)

@external(erlang, "dream_postgres_transport_ffi", "tls_receive")
fn tls_receive(socket: TlsSocket, timeout: Int) -> Result(BitArray, Atom)

@external(erlang, "dream_postgres_transport_ffi", "tls_close")
fn tls_close(socket: TlsSocket) -> Nil

@external(erlang, "dream_postgres_transport_ffi", "peer_certificate")
fn tls_peer_certificate(socket: TlsSocket) -> Result(BitArray, Atom)

@external(erlang, "dream_postgres_transport_ffi", "tcp_receive_next")
fn tcp_receive_next(socket: TcpSocket) -> Result(Nil, Atom)

@external(erlang, "dream_postgres_transport_ffi", "tls_receive_next")
fn tls_receive_next(socket: TlsSocket) -> Result(Nil, Atom)

@external(erlang, "dream_postgres_transport_ffi", "socket_event")
fn socket_event_of(message: Dynamic, socket: socket) -> FfiSocketEvent

@external(erlang, "dream_postgres_transport_ffi", "read_authority_file")
fn read_authority_file(path: String) -> Result(List(BitArray), Atom)

/// Checks a host and a port before any connect.
///
/// ## Parameters
///
/// - `host`: a host name or an IP address, for example `db.example.com`
/// - `port`: the TCP port, 1 to 65535
///
/// ## Returns
///
/// - `Ok(Address)`: the host and port, ready for `connect`
/// - `Error(AddressError)`: the first of the two that cannot be used
pub fn address(host: String, port: Int) -> Result(Address, AddressError) {
  use <- guard(!valid_host(host), Error(InvalidHost(host)))
  use <- guard(port < 1 || port > 65_535, Error(InvalidPort(port)))
  Ok(Address(host:, port:))
}

fn valid_host(host: String) -> Bool {
  host != "" && all(to_utf_codepoints(host), printable_ascii)
}

/// A character from `!` to `~`: ASCII with no space and no control
/// character.
fn printable_ascii(character: UtfCodepoint) -> Bool {
  let code = utf_codepoint_to_int(character)
  code > 32 && code < 127
}

/// The host of an address.
///
/// ## Parameters
///
/// - `address`: the address
///
/// ## Returns
///
/// The host as `address` got it.
pub fn host(address: Address) -> String {
  address.host
}

/// The port of an address.
///
/// ## Parameters
///
/// - `address`: the address
///
/// ## Returns
///
/// The port as `address` got it.
pub fn port(address: Address) -> Int {
  address.port
}

/// Opens a connection: TCP, then TLS as the settings say.
///
/// ## Parameters
///
/// - `config`: the address, the TLS settings and the timeouts
/// - `deadline`: the end of the setup that this connect is part of. Each
///   blocking step (the TCP connect, the answer to the SSLRequest, the TLS
///   handshake, and the plain connects of `PreferTls`) waits for the
///   connect timeout, or for the time left until the deadline when that is
///   shorter.
///
/// ## Returns
///
/// - `Ok(Connection)`: an open connection, ready for the StartupMessage
/// - `Error(TransportError)`: the step that failed. No socket stays open.
pub fn connect(
  config: TransportConfig,
  deadline: Deadline,
) -> Result(Connection, TransportError) {
  let opening = Opening(config:, deadline:)
  use socket <- try(open_tcp(opening))
  case config.tls {
    NoTls -> Ok(PlainConnection(socket))
    PreferTls -> prefer_tls(socket, opening)
    RequireTls(check:, negotiation: PostgresNegotiation) ->
      require_tls(socket, check, opening)
    RequireTls(check:, negotiation: DirectNegotiation) ->
      start_tls(socket, check, opening)
  }
}

/// The settings of one `connect`, and the deadline that each of its
/// blocking steps waits for at most.
type Opening {
  Opening(config: TransportConfig, deadline: Deadline)
}

/// How long one blocking step of the connect may wait: the connect
/// timeout, or the time left until the deadline when that is shorter.
fn step_timeout(opening: Opening) -> Int {
  bounded_wait(opening.deadline, opening.config.connect_timeout_milliseconds)
}

fn open_tcp(opening: Opening) -> Result(TcpSocket, TransportError) {
  let Address(host:, port:) = opening.config.address
  tcp_connect(
    host,
    port,
    step_timeout(opening),
    opening.config.send_timeout_milliseconds,
  )
  |> map_error(connect_error(_, host))
}

/// libpq's `prefer`: TLS without a check when the server accepts it, and a
/// new plain connection when the server refuses, answers with an
/// ErrorResponse, or the handshake fails for any reason. libpq documents
/// `prefer` as "first try an SSL connection; if that fails, try a non-SSL
/// connection", so the handshake error is replaced by the plain connection
/// on purpose.
fn prefer_tls(
  socket: TcpSocket,
  opening: Opening,
) -> Result(Connection, TransportError) {
  case request_tls(socket, opening) {
    Ok(TlsAccepted) -> prefer_handshake(socket, opening)
    Ok(TlsRefused) -> Ok(PlainConnection(socket))
    Ok(TlsAnsweredWithError) -> reconnect_plain(socket, opening)
    Error(error) -> close_with_error(socket, error)
  }
}

fn prefer_handshake(
  socket: TcpSocket,
  opening: Opening,
) -> Result(Connection, TransportError) {
  case start_tls(socket, NoCertificateCheck, opening) {
    Ok(connection) -> Ok(connection)
    Error(_handshake_failed) -> open_tcp(opening) |> map(PlainConnection)
  }
}

fn reconnect_plain(
  socket: TcpSocket,
  opening: Opening,
) -> Result(Connection, TransportError) {
  tcp_close(socket)
  open_tcp(opening) |> map(PlainConnection)
}

fn require_tls(
  socket: TcpSocket,
  check: CertificateCheck,
  opening: Opening,
) -> Result(Connection, TransportError) {
  case request_tls(socket, opening) {
    Ok(TlsAccepted) -> start_tls(socket, check, opening)
    Ok(TlsRefused) -> close_with_error(socket, ServerRefusedTls)
    Ok(TlsAnsweredWithError) ->
      close_with_error(socket, TlsRequestAnsweredWithError)
    Error(error) -> close_with_error(socket, error)
  }
}

/// Sends an SSLRequest and reads the one-byte answer. Bytes after an `S`
/// are an error: they came before TLS.
fn request_tls(
  socket: TcpSocket,
  opening: Opening,
) -> Result(TlsAnswer, TransportError) {
  use Nil <- try(tcp_send(socket, ssl_request()) |> map_error(socket_error))
  read_tls_answer(socket, <<>>, opening)
}

fn read_tls_answer(
  socket: TcpSocket,
  bytes: BitArray,
  opening: Opening,
) -> Result(TlsAnswer, TransportError) {
  case decode_ssl_answer(bytes) {
    NeedMoreBytes -> receive_tls_answer(socket, bytes, opening)
    Decoded(EncryptionAccepted, <<>>) -> Ok(TlsAccepted)
    Decoded(EncryptionAccepted, _rest) -> Error(BytesBeforeTls)
    Decoded(EncryptionRefused, _rest) -> Ok(TlsRefused)
    Decoded(EncryptionErrorResponse, _rest) -> Ok(TlsAnsweredWithError)
    Decoded(UnknownAnswer(answer_byte), _rest) ->
      Error(UnexpectedTlsAnswer(answer_byte))
  }
}

fn receive_tls_answer(
  socket: TcpSocket,
  bytes: BitArray,
  opening: Opening,
) -> Result(TlsAnswer, TransportError) {
  use more <- try(
    tcp_receive(socket, step_timeout(opening))
    |> map_error(socket_error),
  )
  read_tls_answer(socket, <<bytes:bits, more:bits>>, opening)
}

fn start_tls(
  socket: TcpSocket,
  check: CertificateCheck,
  opening: Opening,
) -> Result(Connection, TransportError) {
  case tls_settings(check) {
    Ok(#(peer_check, authorities)) ->
      handshake(socket, peer_check, authorities, opening)
    Error(error) -> close_with_error(socket, error)
  }
}

fn handshake(
  socket: TcpSocket,
  peer_check: PeerCheck,
  authorities: AuthorityList,
  opening: Opening,
) -> Result(Connection, TransportError) {
  let Address(host:, ..) = opening.config.address
  let timeout = step_timeout(opening)
  case tls_connect(socket, peer_check, authorities, host, timeout) {
    Ok(tls_socket) -> Ok(TlsConnection(tls_socket))
    Error(reason) -> close_with_error(socket, tls_error(reason))
  }
}

fn tls_settings(
  check: CertificateCheck,
) -> Result(#(PeerCheck, AuthorityList), TransportError) {
  case check {
    NoCertificateCheck -> Ok(#(SkipCheck, Certificates([])))
    CheckAuthority(authorities:) ->
      authority_list(authorities) |> map(pair.new(Authority, _))
    CheckAuthorityAndHost(authorities:) ->
      authority_list(authorities) |> map(pair.new(AuthorityAndHost, _))
  }
}

fn authority_list(
  authorities: Authorities,
) -> Result(AuthorityList, TransportError) {
  case authorities {
    SystemAuthorities -> Ok(System)
    AuthorityCertificates(certificates:) -> Ok(Certificates(certificates))
    AuthorityFile(path:) -> authority_file(path)
  }
}

fn authority_file(path: String) -> Result(AuthorityList, TransportError) {
  case read_authority_file(path) {
    Ok([]) -> Error(TlsFailed(AuthorityFileEmpty(path)))
    Ok(certificates) -> Ok(Certificates(certificates))
    Error(reason) ->
      Error(TlsFailed(AuthorityFileUnreadable(path, atom.to_string(reason))))
  }
}

fn close_with_error(
  socket: TcpSocket,
  error: TransportError,
) -> Result(a, TransportError) {
  tcp_close(socket)
  Error(error)
}

/// Sends bytes.
///
/// ## Parameters
///
/// - `connection`: an open connection
/// - `bytes`: the bytes to send, for example from `encode`
///
/// ## Returns
///
/// - `Ok(Nil)`: the bytes went to the socket
/// - `Error(TransportError)`: the socket failed
pub fn send(
  connection: Connection,
  bytes: BitArray,
) -> Result(Nil, TransportError) {
  case connection {
    PlainConnection(socket:) -> tcp_send(socket, bytes)
    TlsConnection(socket:) -> tls_send(socket, bytes)
  }
  |> map_error(send_error)
}

/// Waits for bytes, and gives all the bytes that have come.
///
/// ## Parameters
///
/// - `connection`: an open connection
/// - `timeout_milliseconds`: the longest time to wait
///
/// ## Returns
///
/// - `Ok(bytes)`: one or more bytes
/// - `Error(ReceiveTimedOut)`: no byte came in time
/// - `Error(TransportError)`: the socket failed or closed
pub fn receive(
  connection: Connection,
  timeout_milliseconds: Int,
) -> Result(BitArray, TransportError) {
  case connection {
    PlainConnection(socket:) -> tcp_receive(socket, timeout_milliseconds)
    TlsConnection(socket:) -> tls_receive(socket, timeout_milliseconds)
  }
  |> map_error(socket_error)
}

/// Closes the connection. Closing a closed connection does nothing.
///
/// ## Parameters
///
/// - `connection`: the connection to close
///
/// ## Returns
///
/// `Nil`.
pub fn close(connection: Connection) -> Nil {
  case connection {
    PlainConnection(socket:) -> tcp_close(socket)
    TlsConnection(socket:) -> tls_close(socket)
  }
}

/// The DER bytes of the server's certificate, for SCRAM channel binding.
///
/// ## Parameters
///
/// - `connection`: an open connection
///
/// ## Returns
///
/// - `Some(bytes)`: the certificate of a TLS connection
/// - `None`: a plain connection, which has no certificate
pub fn server_certificate(connection: Connection) -> Option(BitArray) {
  case connection {
    PlainConnection(_) -> None
    TlsConnection(socket:) -> tls_peer_certificate(socket) |> option.from_result
  }
}

/// Turns the reason of a failed TCP connect into a typed error.
///
/// ## Parameters
///
/// - `reason`: the error atom of `gen_tcp:connect`
/// - `host`: the host of the connect, for a failed DNS lookup
///
/// ## Returns
///
/// The typed error.
pub fn connect_error(reason: Atom, host: String) -> TransportError {
  case atom.to_string(reason) {
    "nxdomain" -> DnsLookupFailed(host)
    "timeout" -> ConnectTimedOut
    _ -> socket_error(reason)
  }
}

/// Turns the reason of a failed socket call into a typed error.
///
/// ## Parameters
///
/// - `reason`: the error atom of `gen_tcp` or `ssl`
///
/// ## Returns
///
/// The typed error. A reason with no variant of its own is `Unlisted`.
pub fn socket_error(reason: Atom) -> TransportError {
  case atom.to_string(reason) {
    "econnrefused" -> ConnectRefused
    // A call on a socket that is closed already gives einval or enotconn
    // on some systems, and closed on others.
    "closed" | "enotconn" | "einval" -> SocketClosed
    "econnreset" -> ConnectionReset
    "timeout" -> ReceiveTimedOut
    name -> Unlisted(name)
  }
}

/// Turns the reason of a failed send into a typed error.
///
/// ## Parameters
///
/// - `reason`: the error atom of `gen_tcp:send` or `ssl:send`
///
/// ## Returns
///
/// `SendTimedOut` for a send timeout, else the error of `socket_error`.
pub fn send_error(reason: Atom) -> TransportError {
  case atom.to_string(reason) {
    "timeout" -> SendTimedOut
    _ -> socket_error(reason)
  }
}

/// Turns the reason of a failed TLS handshake into a typed error.
///
/// ## Parameters
///
/// - `reason`: the failed certificate check, or the TLS alert
///
/// ## Returns
///
/// The typed error.
pub fn tls_error(reason: Atom) -> TransportError {
  case atom.to_string(reason) {
    "hostname_check_failed" -> TlsFailed(HostNameMismatch)
    "unknown_ca" -> TlsFailed(UnknownAuthority)
    "cert_expired" -> TlsFailed(CertificateExpired)
    "closed" -> SocketClosed
    "timeout" -> ConnectTimedOut
    name -> TlsFailed(OtherTlsFailure(name))
  }
}

/// Asks the socket to send its next bytes to the process that owns the
/// connection, as one message, which `socket_event` reads. After that one
/// message the socket waits for the next call. The owner gets a message
/// at once when the server closes the connection, even while it is idle.
///
/// ## Parameters
///
/// - `connection`: a connection that the calling process owns
///
/// ## Returns
///
/// - `Ok(Nil)`: the next bytes, the close or the error comes as a message
/// - `Error(TransportError)`: the socket is closed already
pub fn receive_next(connection: Connection) -> Result(Nil, TransportError) {
  case connection {
    PlainConnection(socket:) -> tcp_receive_next(socket)
    TlsConnection(socket:) -> tls_receive_next(socket)
  }
  |> map_error(socket_error)
}

/// Reads a message that the owner process got, after `receive_next`.
///
/// ## Parameters
///
/// - `connection`: the connection that the message may be about
/// - `message`: any message of the owner's mailbox
///
/// ## Returns
///
/// The event, or `NotThisSocket` for any other message.
pub fn socket_event(connection: Connection, message: Dynamic) -> SocketEvent {
  let event = case connection {
    PlainConnection(socket:) -> socket_event_of(message, socket)
    TlsConnection(socket:) -> socket_event_of(message, socket)
  }
  case event {
    Received(bytes) -> BytesReceived(bytes)
    Ended -> SocketEnded
    Failed(reason) -> SocketFailed(socket_error(reason))
    Other -> NotThisSocket
  }
}
