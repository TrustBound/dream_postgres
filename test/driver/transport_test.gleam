//// Tests for `dream_postgres/driver/transport`: each TLS setting against the
//// driver servers of PostgreSQL 16 to 19, each failure against a fake
//// server or a port with no listener, and the mapping of each OS and TLS
//// error.

import dream_postgres/driver/message.{AuthenticationOk, AuthenticationSasl}
import dream_postgres/driver/transport.{
  type AddressError, type Tls, type TransportConfig, type TransportError,
  AuthorityCertificates, AuthorityFile, AuthorityFileEmpty,
  AuthorityFileUnreadable, BytesBeforeTls, CertificateExpired, CheckAuthority,
  CheckAuthorityAndHost, ConnectRefused, ConnectTimedOut, ConnectionReset,
  DirectNegotiation, DnsLookupFailed, HostNameMismatch, InvalidHost, InvalidPort,
  NoCertificateCheck, NoTls, OtherTlsFailure, PostgresNegotiation, PreferTls,
  ReceiveTimedOut, RequireTls, SendTimedOut, ServerRefusedTls, SocketClosed,
  SystemAuthorities, TlsFailed, TlsRequestAnsweredWithError, TransportConfig,
  UnexpectedTlsAnswer, UnknownAuthority, Unlisted, address, connect,
  connect_error, send_error, socket_error, tls_error,
}
import dream_test/matchers.{
  be_equal, be_error, be_ok, be_true, or_fail_with, should,
}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import driver/fake_server.{
  type FakeBehavior, Answer, NotTls, Reset, Tls, free_port, start_fake_server,
}
import driver/servers.{type Server, driver_servers, first_driver_server}
import fixtures/driver_tls.{certificate_authority, verify_full}
import gleam/erlang/atom.{type Atom}
import gleam/int.{to_string}
import gleam/list.{map}
import gleam/option.{None, Some}
import gleam/result.{replace_error, try}
import matchers/close_connection.{close_connection}
import matchers/extract_address_parts.{extract_address_parts}
import matchers/extract_client_closed.{extract_client_closed}
import matchers/extract_receive_result.{extract_receive_result}
import matchers/extract_send_result.{extract_send_result}
import matchers/extract_server_certificate.{extract_server_certificate}
import matchers/extract_startup_answer.{extract_startup_answer}

@external(erlang, "dream_postgres_transport_ffi", "reason_name")
fn reason_name(reason: #(Atom, Atom)) -> Atom

@external(erlang, "driver_file_ffi", "read_pem_certificate")
fn read_pem_certificate(path: String) -> BitArray

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
      let checked = address("db.example.com", 6543)

      // Assert
      checked
      |> should
      |> be_ok
      |> extract_address_parts
      |> be_equal(#("db.example.com", 6543))
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
  it("refuses " <> name, fn() {
    // Act
    let checked = address(host, port)

    // Assert
    checked
    |> should
    |> be_error
    |> be_equal(error)
    |> or_fail_with("Expected the address error")
  })
}

// Real servers ----------------------------------------------------------------

fn server_tests(server: Server) {
  group("PostgreSQL " <> to_string(server.version), [
    it("logs in over plain TCP with NoTls", fn() {
      // Arrange
      let config = transport_config("localhost", server.port, NoTls)

      // Act
      let connected = try(config, connect)

      // Assert
      connected
      |> should
      |> extract_startup_answer
      |> be_ok
      |> be_equal(#(AuthenticationOk, False))
      |> or_fail_with("Expected AuthenticationOk over plain TCP")
    }),
    it("logs in over TLS with PreferTls", fn() {
      // Arrange
      let config = transport_config("localhost", server.port, PreferTls)

      // Act
      let connected = try(config, connect)

      // Assert
      connected
      |> should
      |> extract_startup_answer
      |> be_ok
      |> be_equal(#(AuthenticationOk, True))
      |> or_fail_with("Expected AuthenticationOk over TLS")
    }),
    it("logs in over TLS with no certificate check", fn() {
      // Arrange
      let tls = RequireTls(NoCertificateCheck, PostgresNegotiation)
      let config = transport_config("localhost", server.port, tls)

      // Act
      let connected = try(config, connect)

      // Assert
      connected
      |> should
      |> extract_startup_answer
      |> be_ok
      |> be_equal(#(AuthenticationOk, True))
      |> or_fail_with("Expected AuthenticationOk over TLS")
    }),
    it("checks the CA but not the host name with CheckAuthority", fn() {
      // Arrange
      let tls =
        RequireTls(
          CheckAuthority(AuthorityFile(certificate_authority)),
          PostgresNegotiation,
        )
      let config = transport_config("127.0.0.1", server.port, tls)

      // Act
      let connected = try(config, connect)

      // Assert
      connected
      |> should
      |> extract_startup_answer
      |> be_ok
      |> be_equal(#(AuthenticationOk, True))
      |> or_fail_with("Expected AuthenticationOk over TLS")
    }),
    it("checks the CA and the host name with CheckAuthorityAndHost", fn() {
      // Arrange
      let config = transport_config("localhost", server.port, verify_full())

      // Act
      let connected = try(config, connect)

      // Assert
      connected
      |> should
      |> extract_startup_answer
      |> be_ok
      |> be_equal(#(AuthenticationOk, True))
      |> or_fail_with("Expected AuthenticationOk over TLS")
    }),
    it("takes the CA certificates as DER bytes", fn() {
      // Arrange
      let authorities =
        AuthorityCertificates([read_pem_certificate(certificate_authority)])
      let tls =
        RequireTls(CheckAuthorityAndHost(authorities), PostgresNegotiation)
      let config = transport_config("localhost", server.port, tls)

      // Act
      let connected = try(config, connect)

      // Assert
      connected
      |> should
      |> extract_startup_answer
      |> be_ok
      |> be_equal(#(AuthenticationOk, True))
      |> or_fail_with("Expected AuthenticationOk over TLS")
    }),
    it("refuses a host name that the certificate does not name", fn() {
      // Arrange
      let config = transport_config("127.0.0.1", server.port, verify_full())

      // Act
      let connected = try(config, connect)

      // Assert
      connected
      |> should
      |> extract_startup_answer
      |> be_error
      |> be_equal(TlsFailed(HostNameMismatch))
      |> or_fail_with("Expected the connect error")
    }),
    it("refuses the test CA when only the system CAs are trusted", fn() {
      // Arrange
      let tls =
        RequireTls(
          CheckAuthorityAndHost(SystemAuthorities),
          PostgresNegotiation,
        )
      let config = transport_config("localhost", server.port, tls)

      // Act
      let connected = try(config, connect)

      // Assert
      connected
      |> should
      |> extract_startup_answer
      |> be_error
      |> be_equal(TlsFailed(UnknownAuthority))
      |> or_fail_with("Expected the connect error")
    }),
    direct_tls_test(server),
    it("gives the server's certificate for channel binding", fn() {
      // Arrange
      let expected = read_pem_certificate("test/fixtures/ssl/server.crt")
      let config = transport_config("localhost", server.port, verify_full())

      // Act
      let connected = try(config, connect)

      // Assert
      connected
      |> should
      |> be_ok
      |> extract_server_certificate
      |> be_equal(Some(expected))
      |> or_fail_with("Expected the DER bytes of server.crt")
    }),
  ])
}

fn direct_tls() -> Tls {
  RequireTls(
    CheckAuthorityAndHost(AuthorityFile(certificate_authority)),
    DirectNegotiation,
  )
}

/// PostgreSQL 17 and later accept direct TLS. PostgreSQL 16 reads the TLS
/// hello as a startup packet and closes the connection.
fn direct_tls_test(server: Server) {
  case server.version {
    16 ->
      it("closes a direct TLS connection on PostgreSQL 16", fn() {
        // Arrange
        let config = transport_config("localhost", server.port, direct_tls())

        // Act
        let connected = try(config, connect)

        // Assert
        connected
        |> should
        |> extract_startup_answer
        |> be_error
        |> be_equal(SocketClosed)
        |> or_fail_with("Expected the connect error")
      })
    _ ->
      it("logs in over direct TLS", fn() {
        // Arrange
        let config = transport_config("localhost", server.port, direct_tls())

        // Act
        let connected = try(config, connect)

        // Assert
        connected
        |> should
        |> extract_startup_answer
        |> be_ok
        |> be_equal(#(AuthenticationOk, True))
        |> or_fail_with("Expected AuthenticationOk over TLS")
      })
  }
}

/// The transport settings for a host and a port, with a timeout of five
/// seconds. An address that the transport refuses gives an error.
fn transport_config(
  host: String,
  port: Int,
  tls: Tls,
) -> Result(TransportConfig, TransportError) {
  address(host, port)
  |> result.map(TransportConfig(_, tls, 5000, 5000))
  |> replace_error(Unlisted("test address"))
}

// Refusals --------------------------------------------------------------------

/// The PostgreSQL 16 server of the client tests, with SSL off.
const server_without_tls = 5436

fn refusal_tests() {
  [
    it(
      "gives ServerRefusedTls when TLS is required and the server says N",
      fn() {
        // Arrange
        let config =
          transport_config("localhost", server_without_tls, verify_full())

        // Act
        let connected = try(config, connect)

        // Assert
        connected
        |> should
        |> extract_startup_answer
        |> be_error
        |> be_equal(ServerRefusedTls)
        |> or_fail_with("Expected ServerRefusedTls")
      },
    ),
    it("goes on over plain TCP with PreferTls when the server says N", fn() {
      // Arrange
      let config = transport_config("localhost", server_without_tls, PreferTls)

      // Act
      let connected = try(config, connect)

      // Assert
      connected
      |> should
      |> extract_startup_answer
      |> be_ok
      |> be_equal(#(AuthenticationSasl(["SCRAM-SHA-256"]), False))
      |> or_fail_with("Expected the plain login request of the server")
    }),
    fake_error_test(
      "gives the typed error for an unknown answer byte",
      Answer(<<"X">>),
      verify_full(),
      UnexpectedTlsAnswer(88),
    ),
    fake_error_test(
      "gives the typed error for bytes after the S",
      Answer(<<"S", "R":utf8>>),
      verify_full(),
      BytesBeforeTls,
    ),
    fake_error_test(
      "gives the typed error for an ErrorResponse to the SSLRequest",
      Answer(<<"E", 0, 0, 0, 5, 0>>),
      verify_full(),
      TlsRequestAnsweredWithError,
    ),
    fake_error_test(
      "gives a TLS failure for an expired certificate",
      Tls("test/fixtures/ssl/expired.crt", "test/fixtures/ssl/expired.key"),
      verify_full(),
      TlsFailed(CertificateExpired),
    ),
    fake_error_test(
      "gives the typed error for a reset after the SSLRequest",
      Reset,
      verify_full(),
      ConnectionReset,
    ),
    fake_closed_test("an unknown answer byte", Answer(<<"X">>)),
    fake_closed_test("bytes after the S", Answer(<<"S", "R":utf8>>)),
    fake_closed_test("an ErrorResponse to the SSLRequest", Answer(<<"E">>)),
    fake_closed_test("an N with TLS required", Answer(<<"N">>)),
    prefer_reconnects_test("an ErrorResponse", Answer(<<"E">>)),
    prefer_reconnects_test("a failed handshake", NotTls),
    fake_error_test(
      "gives the typed error for an unknown answer byte with PreferTls",
      Answer(<<"X">>),
      PreferTls,
      UnexpectedTlsAnswer(88),
    ),
    fake_error_test(
      "gives a TLS failure for a handshake that gets bytes that are not TLS",
      NotTls,
      verify_full(),
      TlsFailed(OtherTlsFailure("unexpected_message")),
    ),
    fake_error_test(
      "gives a TLS failure for a certificate with an unknown critical extension",
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
  it(name, fn() {
    // Arrange
    let #(port, _server) = start_fake_server(behavior)
    let config = transport_config("localhost", port, tls)

    // Act
    let connected = try(config, connect)

    // Assert
    connected
    |> should
    |> be_error
    |> be_equal(error)
    |> or_fail_with("Expected the typed error")
  })
}

fn fake_closed_test(name: String, behavior: FakeBehavior) {
  it("closes the socket after " <> name, fn() {
    // Arrange
    let #(port, server) = start_fake_server(behavior)
    let config = transport_config("localhost", port, verify_full())

    // Act
    let connected = try(config, connect)

    // Assert
    connected
    |> should
    |> be_error
    |> extract_client_closed(server)
    |> be_true
    |> or_fail_with("Expected the client to close its socket")
  })
}

fn prefer_reconnects_test(name: String, behavior: FakeBehavior) {
  it("connects again over plain TCP with PreferTls after " <> name, fn() {
    // Arrange
    let #(port, _server) = start_fake_server(behavior)
    let config = transport_config("localhost", port, PreferTls)

    // Act
    let connected = try(config, connect)

    // Assert
    connected
    |> should
    |> be_ok
    |> extract_server_certificate
    |> be_equal(None)
    |> or_fail_with("Expected a second, plain connection")
  })
}

// Connect failures ------------------------------------------------------------

fn connect_failure_tests() {
  [
    it("gives ConnectRefused for a port with no listener", fn() {
      // Arrange
      let config = transport_config("localhost", free_port(), NoTls)

      // Act
      let connected = try(config, connect)

      // Assert
      connected
      |> should
      |> be_error
      |> be_equal(ConnectRefused)
      |> or_fail_with("Expected ConnectRefused")
    }),
    it("gives DnsLookupFailed with the host for a name with no address", fn() {
      // Arrange
      let config = transport_config("no-such-host.invalid", 5432, NoTls)

      // Act
      let connected = try(config, connect)

      // Assert
      connected
      |> should
      |> be_error
      |> be_equal(DnsLookupFailed("no-such-host.invalid"))
      |> or_fail_with("Expected DnsLookupFailed")
    }),
    it("gives AuthorityFileUnreadable for a CA file that does not exist", fn() {
      // Arrange
      let tls =
        RequireTls(
          CheckAuthority(AuthorityFile("test/fixtures/ssl/missing.crt")),
          PostgresNegotiation,
        )
      let config = transport_config("localhost", first_driver_server.port, tls)

      // Act
      let connected = try(config, connect)

      // Assert
      connected
      |> should
      |> be_error
      |> be_equal(
        TlsFailed(AuthorityFileUnreadable(
          "test/fixtures/ssl/missing.crt",
          "enoent",
        )),
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
      let config = transport_config("localhost", first_driver_server.port, tls)

      // Act
      let connected = try(config, connect)

      // Assert
      connected
      |> should
      |> be_error
      |> be_equal(
        TlsFailed(AuthorityFileEmpty("test/fixtures/ssl/no_certificate.pem")),
      )
      |> or_fail_with("Expected AuthorityFileEmpty")
    }),
  ]
}

// Reading and writing ---------------------------------------------------------

fn socket_tests() {
  [
    it("gives ReceiveTimedOut when the server sends nothing", fn() {
      // Arrange
      let config =
        transport_config("localhost", first_driver_server.port, NoTls)

      // Act
      let connected = try(config, connect)

      // Assert
      connected
      |> should
      |> be_ok
      |> extract_receive_result(timeout: 50)
      |> be_error
      |> be_equal(ReceiveTimedOut)
      |> or_fail_with("Expected ReceiveTimedOut")
    }),
    it("gives SocketClosed for a send on a closed connection", fn() {
      // Arrange
      let config =
        transport_config("localhost", first_driver_server.port, NoTls)

      // Act
      let connected = try(config, connect)

      // Assert
      connected
      |> should
      |> be_ok
      |> close_connection
      |> extract_send_result(<<"X", 4:32>>)
      |> be_error
      |> be_equal(SocketClosed)
      |> or_fail_with("Expected SocketClosed")
    }),
    it("gives SocketClosed for a send on a closed TLS connection", fn() {
      // Arrange
      let config =
        transport_config("localhost", first_driver_server.port, verify_full())

      // Act
      let connected = try(config, connect)

      // Assert
      connected
      |> should
      |> be_ok
      |> close_connection
      |> extract_send_result(<<"X", 4:32>>)
      |> be_error
      |> be_equal(SocketClosed)
      |> or_fail_with("Expected SocketClosed")
    }),
    it("gives SocketClosed for a receive on a closed TLS connection", fn() {
      // Arrange
      let config =
        transport_config("localhost", first_driver_server.port, verify_full())

      // Act
      let connected = try(config, connect)

      // Assert
      connected
      |> should
      |> be_ok
      |> close_connection
      |> extract_receive_result(timeout: 50)
      |> be_error
      |> be_equal(SocketClosed)
      |> or_fail_with("Expected SocketClosed")
    }),
  ]
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
    connect_reason_test("nxdomain", DnsLookupFailed("db")),
    connect_reason_test("timeout", ConnectTimedOut),
    connect_reason_test("econnrefused", ConnectRefused),
    socket_reason_test("closed", SocketClosed),
    socket_reason_test("enotconn", SocketClosed),
    socket_reason_test("einval", SocketClosed),
    socket_reason_test("econnreset", ConnectionReset),
    socket_reason_test("timeout", ReceiveTimedOut),
    socket_reason_test("ehostunreach", Unlisted("ehostunreach")),
    send_reason_test("timeout", SendTimedOut),
    send_reason_test("closed", SocketClosed),
    tls_reason_test("hostname_check_failed", TlsFailed(HostNameMismatch)),
    tls_reason_test("unknown_ca", TlsFailed(UnknownAuthority)),
    tls_reason_test("cert_expired", TlsFailed(CertificateExpired)),
    tls_reason_test("closed", SocketClosed),
    tls_reason_test("timeout", ConnectTimedOut),
    tls_reason_test(
      "handshake_failure",
      TlsFailed(OtherTlsFailure("handshake_failure")),
    ),
  ]
}

fn connect_reason_test(reason: String, expected: TransportError) {
  it("maps the reason " <> reason <> " of a connect", fn() {
    // Arrange
    let reason_atom = atom.create(reason)

    // Act
    let error = connect_error(reason_atom, "db")

    // Assert
    error
    |> should
    |> be_equal(expected)
    |> or_fail_with("Expected the typed error")
  })
}

fn socket_reason_test(reason: String, expected: TransportError) {
  it("maps the reason " <> reason <> " of a socket call", fn() {
    // Arrange
    let reason_atom = atom.create(reason)

    // Act
    let error = socket_error(reason_atom)

    // Assert
    error
    |> should
    |> be_equal(expected)
    |> or_fail_with("Expected the typed error")
  })
}

fn send_reason_test(reason: String, expected: TransportError) {
  it("maps the reason " <> reason <> " of a send", fn() {
    // Arrange
    let reason_atom = atom.create(reason)

    // Act
    let error = send_error(reason_atom)

    // Assert
    error
    |> should
    |> be_equal(expected)
    |> or_fail_with("Expected the typed error")
  })
}

fn tls_reason_test(reason: String, expected: TransportError) {
  it("maps the reason " <> reason <> " of a TLS handshake", fn() {
    // Arrange
    let reason_atom = atom.create(reason)

    // Act
    let error = tls_error(reason_atom)

    // Assert
    error
    |> should
    |> be_equal(expected)
    |> or_fail_with("Expected the typed error")
  })
}
