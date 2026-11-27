//// Tests for `dream_postgres/driver/transport`: each TLS setting against the
//// driver servers of PostgreSQL 16 to 19, each failure against a fake
//// server or a port with no listener, and the mapping of each OS and TLS
//// error.

import dream_postgres/driver/decode.{decode_backend}
import dream_postgres/driver/encode.{encode}
import dream_postgres/driver/message.{
  type BackendMessage, AuthenticationOk, AuthenticationSasl, Decoded, Protocol30,
  StartupMessage,
}
import dream_postgres/driver/transport.{
  type Address, type AddressError, type Connection, type Tls,
  type TransportError, AuthorityCertificates, AuthorityFile, AuthorityFileEmpty,
  AuthorityFileUnreadable, BytesBeforeTls, CertificateExpired, CheckAuthority,
  CheckAuthorityAndHost, ConnectRefused, ConnectTimedOut, ConnectionReset,
  DirectNegotiation, DnsLookupFailed, HostNameMismatch, InvalidHost, InvalidPort,
  NoCertificateCheck, NoTls, OtherTlsFailure, PostgresNegotiation, PreferTls,
  ReceiveTimedOut, RequireTls, SendTimedOut, ServerRefusedTls, SocketClosed,
  SystemAuthorities, TlsFailed, TlsRequestAnsweredWithError, TransportConfig,
  UnexpectedTlsAnswer, UnknownAuthority, Unlisted, address, close, connect,
  connect_error, receive, send, send_error, server_certificate, socket_error,
  tls_error,
}
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import driver/servers.{type Server, driver_servers}
import gleam/erlang/atom.{type Atom}
import gleam/int.{to_string}
import gleam/list.{map}
import gleam/option.{None, Some}
import gleam/pair
import gleam/result.{try}

@external(erlang, "port_ffi", "free_port")
fn free_port() -> Int

@external(erlang, "driver_fake_server_ffi", "start")
fn start_fake_server(behavior: FakeBehavior) -> #(Int, FakeServer)

@external(erlang, "driver_fake_server_ffi", "client_closed")
fn client_closed(server: FakeServer) -> Bool

@external(erlang, "dream_postgres_transport_ffi", "reason_name")
fn reason_name(reason: #(Atom, Atom)) -> Atom

@external(erlang, "driver_file_ffi", "read_pem_certificate")
fn read_pem_certificate(path: String) -> BitArray

type FakeServer

/// What the fake server does after the SSLRequest.
type FakeBehavior {
  Answer(BitArray)
  Reset
  NotTls
  Tls(String, String)
}

const certificate_authority = "test/fixtures/ssl/ca.crt"

/// The tests of the transport.
pub fn tests() -> TestSuite {
  describe("dream_postgres/driver/transport", [
    group("addresses", address_tests()),
    group(
      "each TLS setting on each driver server",
      map(driver_servers(), server_tests),
    ),
    group("servers that refuse or misbehave", refusal_tests()),
    group("connect failures", connect_failure_tests()),
    group("reading and writing", socket_tests()),
    group("the error of each OS reason", reason_tests()),
  ])
}

// Addresses -------------------------------------------------------------------

fn address_tests() {
  [
    address_error_test("an empty host", "", 5432, InvalidHost("")),
    address_error_test(
      "a host with a space",
      "db host",
      5432,
      InvalidHost("db host"),
    ),
    address_error_test(
      "a host with a control character",
      "db\nhost",
      5432,
      InvalidHost("db\nhost"),
    ),
    address_error_test("a host outside ASCII", "dbé", 5432, InvalidHost("dbé")),
    address_error_test("port 0", "localhost", 0, InvalidPort(0)),
    address_error_test("port 65536", "localhost", 65_536, InvalidPort(65_536)),
    it("keeps the host and the port of a valid address", fn() {
      // Act
      let parts = address("db.example.com", 6543) |> result.map(address_parts)

      // Assert
      parts
      |> should
      |> be_equal(Ok(#("db.example.com", 6543)))
      |> or_fail_with("Expected the host and the port")
    }),
  ]
}

fn address_error_test(
  name: String,
  host: String,
  port: Int,
  error: AddressError,
) {
  it("refuses " <> name, fn() { check_address_error(host, port, error) })
}

fn check_address_error(host: String, port: Int, error: AddressError) {
  // Act
  let checked = address(host, port) |> result.map(address_parts)

  // Assert
  checked
  |> should
  |> be_equal(Error(error))
  |> or_fail_with("Expected the address error")
}

fn address_parts(address: Address) -> #(String, Int) {
  #(transport.host(address), transport.port(address))
}

// Real servers ----------------------------------------------------------------

fn server_tests(server: Server) {
  group("PostgreSQL " <> to_string(server.version), [
    it("logs in over plain TCP with NoTls", fn() {
      check_login(server, "localhost", NoTls, False)
    }),
    it("logs in over TLS with PreferTls", fn() {
      check_login(server, "localhost", PreferTls, True)
    }),
    it("logs in over TLS with no certificate check", fn() {
      check_login(
        server,
        "localhost",
        RequireTls(NoCertificateCheck, PostgresNegotiation),
        True,
      )
    }),
    it("checks the CA but not the host name with CheckAuthority", fn() {
      check_login(
        server,
        "127.0.0.1",
        RequireTls(
          CheckAuthority(AuthorityFile(certificate_authority)),
          PostgresNegotiation,
        ),
        True,
      )
    }),
    it("checks the CA and the host name with CheckAuthorityAndHost", fn() {
      check_login(server, "localhost", verify_full(), True)
    }),
    it("takes the CA certificates as DER bytes", fn() {
      check_login(
        server,
        "localhost",
        RequireTls(
          CheckAuthorityAndHost(
            AuthorityCertificates([read_pem_certificate(certificate_authority)]),
          ),
          PostgresNegotiation,
        ),
        True,
      )
    }),
    it("refuses a host name that the certificate does not name", fn() {
      check_connect_error(
        server,
        "127.0.0.1",
        verify_full(),
        TlsFailed(HostNameMismatch),
      )
    }),
    it("refuses the test CA when only the system CAs are trusted", fn() {
      check_connect_error(
        server,
        "localhost",
        RequireTls(
          CheckAuthorityAndHost(SystemAuthorities),
          PostgresNegotiation,
        ),
        TlsFailed(UnknownAuthority),
      )
    }),
    direct_tls_test(server),
    it("gives the server's certificate for channel binding", fn() {
      check_server_certificate(server)
    }),
  ])
}

fn verify_full() -> Tls {
  RequireTls(
    CheckAuthorityAndHost(AuthorityFile(certificate_authority)),
    PostgresNegotiation,
  )
}

/// PostgreSQL 17 and later accept direct TLS. PostgreSQL 16 reads the TLS
/// hello as a startup packet and closes the connection.
fn direct_tls_test(server: Server) {
  let tls =
    RequireTls(
      CheckAuthorityAndHost(AuthorityFile(certificate_authority)),
      DirectNegotiation,
    )
  case server.version {
    16 ->
      it("closes a direct TLS connection on PostgreSQL 16", fn() {
        check_connect_error(server, "localhost", tls, SocketClosed)
      })
    _ ->
      it("logs in over direct TLS", fn() {
        check_login(server, "localhost", tls, True)
      })
  }
}

fn config(
  host: String,
  port: Int,
  tls: Tls,
) -> Result(transport.TransportConfig, TransportError) {
  case address(host, port) {
    Ok(checked) -> Ok(TransportConfig(checked, tls, 5000, 5000))
    Error(_) -> Error(Unlisted("test address"))
  }
}

/// Connects, sends a StartupMessage for dream_trust, and reads the first
/// answer: AuthenticationOk proves the bytes went both ways. The result is
/// that message and whether the connection has a server certificate.
fn login(
  host: String,
  port: Int,
  tls: Tls,
) -> Result(#(BackendMessage, Bool), TransportError) {
  use transport_config <- try(config(host, port, tls))
  use connection <- try(connect(transport_config))
  let answer = first_answer(connection)
  let has_certificate = server_certificate(connection) != None
  close(connection)
  answer |> result.map(pair.new(_, has_certificate))
}

fn first_answer(
  connection: Connection,
) -> Result(BackendMessage, TransportError) {
  let startup =
    StartupMessage(Protocol30, "dream_trust", [#("database", servers.database)])
  use bytes <- try(encode(startup) |> result.replace_error(Unlisted("encode")))
  use Nil <- try(send(connection, bytes))
  use answer <- try(receive(connection, 5000))
  case decode_backend(answer) {
    Ok(Decoded(message, _rest)) -> Ok(message)
    _ -> Error(Unlisted("decode"))
  }
}

fn check_login(server: Server, host: String, tls: Tls, encrypted: Bool) {
  // Act
  let answer = login(host, server.port, tls)

  // Assert
  answer
  |> should
  |> be_equal(Ok(#(AuthenticationOk, encrypted)))
  |> or_fail_with("Expected AuthenticationOk over the expected transport")
}

fn check_connect_error(
  server: Server,
  host: String,
  tls: Tls,
  error: TransportError,
) {
  // Act
  let answer = login(host, server.port, tls)

  // Assert
  answer
  |> should
  |> be_equal(Error(error))
  |> or_fail_with("Expected the connect error")
}

fn check_server_certificate(server: Server) {
  // Arrange
  let expected = read_pem_certificate("test/fixtures/ssl/server.crt")

  // Act
  let certificate = {
    use transport_config <- try(config("localhost", server.port, verify_full()))
    use connection <- try(connect(transport_config))
    let certificate = server_certificate(connection)
    close(connection)
    Ok(certificate)
  }

  // Assert
  certificate
  |> should
  |> be_equal(Ok(Some(expected)))
  |> or_fail_with("Expected the DER bytes of server.crt")
}

// Refusals --------------------------------------------------------------------

/// The PostgreSQL 16 server of the client tests, with SSL off.
const server_without_tls = 5436

fn refusal_tests() {
  [
    it(
      "gives ServerRefusedTls when TLS is required and the server says N",
      fn() {
        // Act
        let answer = login("localhost", server_without_tls, verify_full())

        // Assert
        answer
        |> should
        |> be_equal(Error(ServerRefusedTls))
        |> or_fail_with("Expected ServerRefusedTls")
      },
    ),
    it("goes on over plain TCP with PreferTls when the server says N", fn() {
      // Act
      let answer = login("localhost", server_without_tls, PreferTls)

      // Assert
      answer
      |> should
      |> be_equal(Ok(#(AuthenticationSasl(["SCRAM-SHA-256"]), False)))
      |> or_fail_with("Expected the plain login request of the server")
    }),
    fake_error_test(
      "an unknown answer byte",
      Answer(<<"X">>),
      verify_full(),
      UnexpectedTlsAnswer(88),
    ),
    fake_error_test(
      "bytes after the S",
      Answer(<<"S", "R":utf8>>),
      verify_full(),
      BytesBeforeTls,
    ),
    fake_error_test(
      "an ErrorResponse to the SSLRequest",
      Answer(<<"E", 0, 0, 0, 5, 0>>),
      verify_full(),
      TlsRequestAnsweredWithError,
    ),
    fake_error_test(
      "an expired certificate",
      Tls("test/fixtures/ssl/expired.crt", "test/fixtures/ssl/expired.key"),
      verify_full(),
      TlsFailed(CertificateExpired),
    ),
    fake_error_test(
      "a reset after the SSLRequest",
      Reset,
      verify_full(),
      ConnectionReset,
    ),
    fake_closed_test("an unknown answer byte", Answer(<<"X">>)),
    fake_closed_test("bytes after the S", Answer(<<"S", "R":utf8>>)),
    fake_closed_test("an ErrorResponse to the SSLRequest", Answer(<<"E">>)),
    fake_closed_test("an N with TLS required", Answer(<<"N">>)),
    it(
      "connects again over plain TCP with PreferTls after an ErrorResponse",
      fn() { check_prefer_reconnects(Answer(<<"E">>)) },
    ),
    it(
      "connects again over plain TCP with PreferTls after a failed handshake",
      fn() { check_prefer_reconnects(NotTls) },
    ),
    fake_error_test(
      "an unknown answer byte with PreferTls",
      Answer(<<"X">>),
      PreferTls,
      UnexpectedTlsAnswer(88),
    ),
    fake_error_test(
      "a handshake that gets bytes that are not TLS",
      NotTls,
      verify_full(),
      TlsFailed(OtherTlsFailure("unexpected_message")),
    ),
    fake_error_test(
      "a certificate with an unknown critical extension",
      Tls(
        "test/fixtures/ssl/unknown_extension.crt",
        "test/fixtures/ssl/unknown_extension.key",
      ),
      verify_full(),
      TlsFailed(OtherTlsFailure("unsupported_certificate")),
    ),
  ]
}

fn fake_error_test(
  name: String,
  behavior: FakeBehavior,
  tls: Tls,
  error: TransportError,
) {
  it("gives " <> describe_error(error) <> " for " <> name, fn() {
    check_fake_error(behavior, tls, error)
  })
}

fn describe_error(error: TransportError) -> String {
  case error {
    TlsFailed(_) -> "a TLS failure"
    _ -> "the typed error"
  }
}

fn check_fake_error(behavior: FakeBehavior, tls: Tls, error: TransportError) {
  // Arrange
  let #(port, _server) = start_fake_server(behavior)

  // Act
  let answer = connect_only("localhost", port, tls)

  // Assert
  answer
  |> should
  |> be_equal(Error(error))
  |> or_fail_with("Expected the typed error")
}

fn fake_closed_test(name: String, behavior: FakeBehavior) {
  it("closes the socket after " <> name, fn() { check_closed(behavior) })
}

fn check_closed(behavior: FakeBehavior) {
  // Arrange
  let #(port, server) = start_fake_server(behavior)
  let _failed = connect_only("localhost", port, verify_full())

  // Act
  let closed = client_closed(server)

  // Assert
  closed
  |> should
  |> be_equal(True)
  |> or_fail_with("Expected the client to close its socket")
}

fn check_prefer_reconnects(behavior: FakeBehavior) {
  // Arrange
  let #(port, _server) = start_fake_server(behavior)

  // Act
  let encrypted = {
    use transport_config <- try(config("localhost", port, PreferTls))
    use connection <- try(connect(transport_config))
    let certificate = server_certificate(connection)
    close(connection)
    Ok(certificate)
  }

  // Assert
  encrypted
  |> should
  |> be_equal(Ok(None))
  |> or_fail_with("Expected a second, plain connection")
}

fn connect_only(
  host: String,
  port: Int,
  tls: Tls,
) -> Result(Nil, TransportError) {
  use transport_config <- try(config(host, port, tls))
  use connection <- try(connect(transport_config))
  close(connection)
  Ok(Nil)
}

// Connect failures ------------------------------------------------------------

fn connect_failure_tests() {
  [
    it("gives ConnectRefused for a port with no listener", fn() {
      // Arrange
      let port = free_port()

      // Act
      let answer = connect_only("localhost", port, NoTls)

      // Assert
      answer
      |> should
      |> be_equal(Error(ConnectRefused))
      |> or_fail_with("Expected ConnectRefused")
    }),
    it("gives DnsLookupFailed with the host for a name with no address", fn() {
      // Act
      let answer = connect_only("no-such-host.invalid", 5432, NoTls)

      // Assert
      answer
      |> should
      |> be_equal(Error(DnsLookupFailed("no-such-host.invalid")))
      |> or_fail_with("Expected DnsLookupFailed")
    }),
    it("gives AuthorityFileUnreadable for a CA file that does not exist", fn() {
      // Arrange
      let tls =
        RequireTls(
          CheckAuthority(AuthorityFile("test/fixtures/ssl/missing.crt")),
          PostgresNegotiation,
        )
      let server = first_server()

      // Act
      let answer = connect_only("localhost", server.port, tls)

      // Assert
      answer
      |> should
      |> be_equal(
        Error(
          TlsFailed(AuthorityFileUnreadable(
            "test/fixtures/ssl/missing.crt",
            "enoent",
          )),
        ),
      )
      |> or_fail_with("Expected AuthorityFileUnreadable")
    }),
    it("gives AuthorityFileEmpty for a CA file with no certificate", fn() {
      // Arrange
      let tls =
        RequireTls(
          CheckAuthority(AuthorityFile("test/fixtures/ssl/no_certificate.pem")),
          PostgresNegotiation,
        )
      let server = first_server()

      // Act
      let answer = connect_only("localhost", server.port, tls)

      // Assert
      answer
      |> should
      |> be_equal(
        Error(
          TlsFailed(AuthorityFileEmpty("test/fixtures/ssl/no_certificate.pem")),
        ),
      )
      |> or_fail_with("Expected AuthorityFileEmpty")
    }),
  ]
}

fn first_server() -> Server {
  case driver_servers() {
    [server, ..] -> server
    [] -> servers.Server(version: 16, port: 5441)
  }
}

// Reading and writing ---------------------------------------------------------

fn socket_tests() {
  [
    it("gives ReceiveTimedOut when the server sends nothing", fn() {
      // Arrange
      let server = first_server()

      // Act
      let answer = {
        use transport_config <- try(config("localhost", server.port, NoTls))
        use connection <- try(connect(transport_config))
        let bytes = receive(connection, 50)
        close(connection)
        bytes
      }

      // Assert
      answer
      |> should
      |> be_equal(Error(ReceiveTimedOut))
      |> or_fail_with("Expected ReceiveTimedOut")
    }),
    it("gives SocketClosed for a send on a closed connection", fn() {
      check_closed_call(PlainSend)
    }),
    it("gives SocketClosed for a send on a closed TLS connection", fn() {
      check_closed_call(TlsSend)
    }),
    it("gives SocketClosed for a receive on a closed TLS connection", fn() {
      check_closed_call(TlsReceive)
    }),
  ]
}

type ClosedCall {
  PlainSend
  TlsSend
  TlsReceive
}

fn check_closed_call(call: ClosedCall) {
  // Arrange
  let server = first_server()
  let tls = case call {
    PlainSend -> NoTls
    TlsSend | TlsReceive -> verify_full()
  }

  // Act
  let answer = {
    use transport_config <- try(config("localhost", server.port, tls))
    use connection <- try(connect(transport_config))
    close(connection)
    closed_call(call, connection)
  }

  // Assert
  answer
  |> should
  |> be_equal(Error(SocketClosed))
  |> or_fail_with("Expected SocketClosed")
}

fn closed_call(
  call: ClosedCall,
  connection: Connection,
) -> Result(Nil, TransportError) {
  case call {
    PlainSend | TlsSend -> send(connection, <<"X", 4:32>>)
    TlsReceive -> receive(connection, 50) |> result.replace(Nil)
  }
}

// Reasons ---------------------------------------------------------------------

fn reason_tests() {
  [
    it("names a reason tuple by its first element", fn() {
      // Arrange
      let reason = #(atom.create("revoked"), atom.create("keyCompromise"))

      // Act
      let name = reason_name(reason)

      // Assert
      name
      |> should
      |> be_equal(atom.create("revoked"))
      |> or_fail_with("Expected the name revoked")
    }),
    reason_test(ConnectReason, "nxdomain", DnsLookupFailed("db")),
    reason_test(ConnectReason, "timeout", ConnectTimedOut),
    reason_test(ConnectReason, "econnrefused", ConnectRefused),
    reason_test(SocketReason, "closed", SocketClosed),
    reason_test(SocketReason, "enotconn", SocketClosed),
    reason_test(SocketReason, "einval", SocketClosed),
    reason_test(SocketReason, "econnreset", ConnectionReset),
    reason_test(SocketReason, "timeout", ReceiveTimedOut),
    reason_test(SocketReason, "ehostunreach", Unlisted("ehostunreach")),
    reason_test(SendReason, "timeout", SendTimedOut),
    reason_test(SendReason, "closed", SocketClosed),
    reason_test(TlsReason, "hostname_check_failed", TlsFailed(HostNameMismatch)),
    reason_test(TlsReason, "unknown_ca", TlsFailed(UnknownAuthority)),
    reason_test(TlsReason, "cert_expired", TlsFailed(CertificateExpired)),
    reason_test(TlsReason, "closed", SocketClosed),
    reason_test(TlsReason, "timeout", ConnectTimedOut),
    reason_test(
      TlsReason,
      "handshake_failure",
      TlsFailed(OtherTlsFailure("handshake_failure")),
    ),
  ]
}

/// Which mapping a reason goes through.
type ReasonKind {
  ConnectReason
  SocketReason
  SendReason
  TlsReason
}

fn reason_test(kind: ReasonKind, reason: String, expected: TransportError) {
  it("maps the reason " <> reason <> " of a " <> kind_name(kind), fn() {
    check_reason(kind, reason, expected)
  })
}

fn kind_name(kind: ReasonKind) -> String {
  case kind {
    ConnectReason -> "connect"
    SocketReason -> "socket call"
    SendReason -> "send"
    TlsReason -> "TLS handshake"
  }
}

fn check_reason(kind: ReasonKind, reason: String, expected: TransportError) {
  // Arrange
  let reason_atom = atom.create(reason)

  // Act
  let error = case kind {
    ConnectReason -> connect_error(reason_atom, "db")
    SocketReason -> socket_error(reason_atom)
    SendReason -> send_error(reason_atom)
    TlsReason -> tls_error(reason_atom)
  }

  // Assert
  error
  |> should
  |> be_equal(expected)
  |> or_fail_with("Expected the typed error")
}
