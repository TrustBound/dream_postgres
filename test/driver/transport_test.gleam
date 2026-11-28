//// Tests for `dream_postgres/driver/transport`: each TLS setting against the
//// driver servers of PostgreSQL 16 to 19, each failure against a fake
//// server or a port with no listener, and the mapping of each OS and TLS
//// error.

import dream_postgres/driver/message.{
  type BackendMessage, AuthenticationOk, AuthenticationSasl,
}
import dream_postgres/driver/transport.{
  type AddressError, type SocketError, type SocketFailure, type Tls,
  type TransportConfig, type TransportError, AuthorityFile, AuthorityFileEmpty,
  AuthorityFileUnreadable, BytesBeforeTls, CertificateExpired, CheckAuthority,
  CheckAuthorityAndHost, ConnectClosed, ConnectRefused, ConnectReset,
  ConnectTimedOut, ConnectUnlisted, ConnectionReset, DirectNegotiation,
  DnsLookupFailed, HostNameMismatch, InvalidHost, InvalidPort,
  NoCertificateCheck, NoTls, OtherReason, OtherTlsFailure, PostgresNegotiation,
  PreferTls, ReasonAtom, ReceiveFailed, ReceiveTimedOut, RequireTls, SendFailed,
  ServerRefusedTls, SocketClosed, SystemAuthorities, TlsAlert, TlsAlertRaised,
  TlsFailed, TlsRequestAnsweredWithError, TransportConfig, UnexpectedTlsAnswer,
  UnknownAuthority, Unlisted, address, close, connect_error, server_certificate,
  socket_error,
}
import dream_test/context
import dream_test/matchers.{
  be_equal, be_error, be_ok, be_true, or_fail_with, should,
}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import dream_test/unit_context
import driver/fake_server.{
  type FakeBehavior, Answer, NotTls, Reset, Tls, free_port, next_message,
  next_socket_message, send_bad_record, start_fake_server,
  start_tls_then_bad_record,
}
import driver/servers.{
  type Server, driver_servers, first_driver_server, server_without_tls,
}
import driver/test_files.{read_pem_certificate}
import driver/transport_reason.{reason_name, socket_failure}
import fixtures/driver_tls.{
  certificate_authority, der_authority_config, transport_config, verify_full,
}
import fixtures/transport_connect.{
  type StartupAnswer, connect_and_answer, connect_with_minute_deadline,
}
import gleam/dynamic
import gleam/erlang/atom
import gleam/int.{to_string}
import gleam/list.{map}
import gleam/option.{None, Some}
import gleam/result.{map_error, try}
import gleam/string.{inspect}
import matchers/be_equal_parts.{be_equal_parts}
import matchers/close_connection.{close_connection}
import matchers/extract_address_parts.{extract_address_parts}
import matchers/extract_client_closed.{extract_client_closed}
import matchers/extract_receive_result.{extract_receive_result}
import matchers/extract_send_result.{extract_send_result}
import matchers/extract_server_certificate.{extract_server_certificate}
import matchers/extract_startup_answer.{extract_startup_answer}

/// The tests of the transport.
pub fn tests() -> TestSuite {
  suite.group("dream_postgres/driver/transport", [
    describe("the transport", [
      group("addresses", address_tests()),
      group(
        "each TLS setting on each driver server",
        map(driver_servers(), server_tests),
      ),
      group("servers that refuse or misbehave", refusal_tests()),
      group("connect failures", connect_failure_tests()),
      group("reading and writing", socket_tests()),
      group("the error of each OS reason", reason_tests()),
    ]),
    suite.group(
      "a login with each TLS setting on each driver server",
      map(driver_servers(), login_tests),
    ),
    login_test(
      "a login that goes on over plain TCP with PreferTls when the server says N",
      fn() { transport_config("localhost", server_without_tls, PreferTls) },
      AuthenticationSasl(["SCRAM-SHA-256"]),
      False,
    ),
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
    it("refuses a host name that the certificate does not name", fn() {
      // Arrange
      let config = transport_config("127.0.0.1", server.port, verify_full())

      // Act
      let connected = try(config, connect_with_minute_deadline)

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
      let connected = try(config, connect_with_minute_deadline)

      // Assert
      connected
      |> should
      |> extract_startup_answer
      |> be_error
      |> be_equal(TlsFailed(UnknownAuthority))
      |> or_fail_with("Expected the connect error")
    }),
    it("gives the server's certificate for channel binding", fn() {
      // Arrange
      let config = transport_config("localhost", server.port, verify_full())

      // Act
      let certificates = {
        use expected <- try(read_pem_certificate("test/fixtures/ssl/server.crt"))
        use connection <- try(
          try(config, connect_with_minute_deadline) |> map_error(inspect),
        )
        let certificate = server_certificate(connection)
        close(connection)
        Ok(#(certificate, Some(expected)))
      }

      // Assert
      certificates
      |> should
      |> be_ok
      |> be_equal_parts
      |> or_fail_with("Expected the DER bytes of server.crt")
    }),
    ..direct_tls_refusal_tests(server)
  ])
}

fn direct_tls() -> Tls {
  RequireTls(
    CheckAuthorityAndHost(AuthorityFile(certificate_authority)),
    DirectNegotiation,
  )
}

/// PostgreSQL 17 and later accept direct TLS (see `login_tests`).
/// PostgreSQL 16 reads the TLS hello as a startup packet and closes the
/// connection.
fn direct_tls_refusal_tests(server: Server) {
  case server.version {
    16 -> [
      it("closes a direct TLS connection on PostgreSQL 16", fn() {
        // Arrange
        let config = transport_config("localhost", server.port, direct_tls())

        // Act
        let connected = try(config, connect_with_minute_deadline)

        // Assert
        connected
        |> should
        |> extract_startup_answer
        |> be_error
        |> be_equal(ConnectClosed)
        |> or_fail_with("Expected the connect error")
      }),
    ]
    _ -> []
  }
}

/// A login that works with each TLS setting. PostgreSQL 17 and later also
/// take direct TLS.
fn login_tests(server: Server) -> TestSuite {
  let port = server.port
  suite.group("PostgreSQL " <> to_string(server.version), [
    login_test(
      "a login over plain TCP with NoTls",
      fn() { transport_config("localhost", port, NoTls) },
      AuthenticationOk,
      False,
    ),
    login_test(
      "a login over TLS with PreferTls",
      fn() { transport_config("localhost", port, PreferTls) },
      AuthenticationOk,
      True,
    ),
    login_test(
      "a login over TLS with no certificate check",
      fn() {
        transport_config(
          "localhost",
          port,
          RequireTls(NoCertificateCheck, PostgresNegotiation),
        )
      },
      AuthenticationOk,
      True,
    ),
    login_test(
      "a login that checks the CA but not the host name with CheckAuthority",
      fn() {
        transport_config(
          "127.0.0.1",
          port,
          RequireTls(
            CheckAuthority(AuthorityFile(certificate_authority)),
            PostgresNegotiation,
          ),
        )
      },
      AuthenticationOk,
      True,
    ),
    login_test(
      "a login that checks the CA and the host name with CheckAuthorityAndHost",
      fn() { transport_config("localhost", port, verify_full()) },
      AuthenticationOk,
      True,
    ),
    login_test(
      "a login that takes the CA certificates as DER bytes",
      fn() { der_authority_config("localhost", port) },
      AuthenticationOk,
      True,
    ),
    ..direct_tls_login_tests(server)
  ])
}

fn direct_tls_login_tests(server: Server) -> List(TestSuite) {
  case server.version {
    16 -> []
    _ -> [
      login_test(
        "a login over direct TLS",
        fn() { transport_config("localhost", server.port, direct_tls()) },
        AuthenticationOk,
        True,
      ),
    ]
  }
}

/// One login, the shared act of two tests: the first answer of the
/// server, and whether the connection is TLS.
fn login_test(
  name: String,
  config: fn() -> Result(TransportConfig, error),
  answer: BackendMessage,
  encrypted: Bool,
) -> TestSuite {
  let kind = case encrypted {
    True -> "TLS"
    False -> "plain TCP"
  }
  unit_context.describe(
    name,
    context.setup(
      setup: fn() { connect_and_answer(config()) },
      teardown: fn(_closed) { Ok(Nil) },
    ),
    [
      unit_context.it(
        "gets " <> inspect(answer) <> " first",
        fn(login: StartupAnswer) {
          login.message
          |> should
          |> be_equal(answer)
          |> or_fail_with("Expected the first answer of the server")
        },
      ),
      unit_context.it("runs over " <> kind, fn(login: StartupAnswer) {
        login.encrypted
        |> should
        |> be_equal(encrypted)
        |> or_fail_with("Expected the TLS of the connection")
      }),
    ],
  )
}

// Refusals --------------------------------------------------------------------

fn refusal_tests() {
  [
    it(
      "gives ServerRefusedTls when TLS is required and the server says N",
      fn() {
        // Arrange
        let config =
          transport_config("localhost", server_without_tls, verify_full())

        // Act
        let connected = try(config, connect_with_minute_deadline)

        // Assert
        connected
        |> should
        |> extract_startup_answer
        |> be_error
        |> be_equal(ServerRefusedTls)
        |> or_fail_with("Expected ServerRefusedTls")
      },
    ),
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
      ConnectReset,
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
    // Act
    let connected = {
      use #(port, _server) <- result.map(start_fake_server(behavior))
      try(
        transport_config("localhost", port, tls),
        connect_with_minute_deadline,
      )
    }

    // Assert
    connected
    |> should
    |> be_ok
    |> be_error
    |> be_equal(error)
    |> or_fail_with("Expected the typed error")
  })
}

fn fake_closed_test(name: String, behavior: FakeBehavior) {
  it("closes the socket after " <> name, fn() {
    // Act
    let connected = {
      use #(port, server) <- result.map(start_fake_server(behavior))
      let config = transport_config("localhost", port, verify_full())
      #(try(config, connect_with_minute_deadline), server)
    }

    // Assert
    connected
    |> should
    |> be_ok
    |> extract_client_closed
    |> be_true
    |> or_fail_with("Expected the client to close its socket")
  })
}

fn prefer_reconnects_test(name: String, behavior: FakeBehavior) {
  it("connects again over plain TCP with PreferTls after " <> name, fn() {
    // Act
    let connected = {
      use #(port, _server) <- result.map(start_fake_server(behavior))
      try(
        transport_config("localhost", port, PreferTls),
        connect_with_minute_deadline,
      )
    }

    // Assert
    connected
    |> should
    |> be_ok
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
      let connected = try(config, connect_with_minute_deadline)

      // Assert
      connected
      |> should
      |> be_error
      |> be_equal(ConnectRefused)
      |> or_fail_with("Expected ConnectRefused")
    }),
    it("gives ConnectTimedOut for a TLS handshake that never ends", fn() {
      // Arrange
      let tls = RequireTls(NoCertificateCheck, PostgresNegotiation)

      // Act
      let connected = {
        use #(port, _server) <- try(
          start_fake_server(Answer(<<"S">>)) |> map_error(ConnectUnlisted),
        )
        use config <- try(transport_config("localhost", port, tls))
        connect_with_minute_deadline(
          TransportConfig(..config, connect_timeout_milliseconds: 100),
        )
      }

      // Assert
      connected
      |> should
      |> be_error
      |> be_equal(ConnectTimedOut)
      |> or_fail_with("Expected ConnectTimedOut for the handshake")
    }),
    it("gives DnsLookupFailed with the host for a name with no address", fn() {
      // Arrange
      let config = transport_config("no-such-host.invalid", 5432, NoTls)

      // Act
      let connected = try(config, connect_with_minute_deadline)

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
      let connected = try(config, connect_with_minute_deadline)

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
      let connected = try(config, connect_with_minute_deadline)

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
      let connected = try(config, connect_with_minute_deadline)

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
      let connected = try(config, connect_with_minute_deadline)

      // Assert
      connected
      |> should
      |> be_ok
      |> close_connection
      |> extract_send_result(<<"X", 4:32>>)
      |> be_error
      |> be_equal(SendFailed(SocketClosed))
      |> or_fail_with("Expected SocketClosed")
    }),
    it("gives SocketClosed for a send on a closed TLS connection", fn() {
      // Arrange
      let config =
        transport_config("localhost", first_driver_server.port, verify_full())

      // Act
      let connected = try(config, connect_with_minute_deadline)

      // Assert
      connected
      |> should
      |> be_ok
      |> close_connection
      |> extract_send_result(<<"X", 4:32>>)
      |> be_error
      |> be_equal(SendFailed(SocketClosed))
      |> or_fail_with("Expected SocketClosed")
    }),
    it("gives the TLS alert of a record that is not valid TLS", fn() {
      // Act
      let event = {
        use #(port, server) <- try(start_tls_then_bad_record(
          "test/fixtures/ssl/server.crt",
          "test/fixtures/ssl/server.key",
        ))
        use connection <- try(
          transport_config(
            "localhost",
            port,
            RequireTls(NoCertificateCheck, PostgresNegotiation),
          )
          |> try(connect_with_minute_deadline)
          |> map_error(inspect),
        )
        use Nil <- try(transport.receive_next(connection) |> map_error(inspect))
        use Nil <- try(send_bad_record(server))
        use message <- try(next_message())
        Ok(transport.socket_event(connection, message))
      }

      // Assert
      event
      |> should
      |> be_ok
      |> be_equal(transport.SocketFailed(TlsAlertRaised("bad_record_mac")))
      |> or_fail_with("Expected the TLS alert as a typed error")
    }),
    it("gives a reset of the server after receive_next as a message", fn() {
      // Act
      let event = {
        use #(port, _server) <- try(start_fake_server(Reset))
        use connection <- try(
          transport_config("localhost", port, NoTls)
          |> try(connect_with_minute_deadline)
          |> map_error(inspect),
        )
        use Nil <- try(transport.receive_next(connection) |> map_error(inspect))
        // The fake server resets once it read 8 bytes.
        use Nil <- try(
          transport.send(connection, <<8:32, 0:32>>) |> map_error(inspect),
        )
        use message <- try(next_socket_message())
        Ok(transport.socket_event(connection, message))
      }

      // Assert
      event
      |> should
      |> be_ok
      |> be_equal(transport.SocketFailed(ConnectionReset))
      |> or_fail_with("Expected the reset as SocketFailed(ConnectionReset)")
    }),
    it("gives SocketClosed for a receive on a closed TLS connection", fn() {
      // Arrange
      let config =
        transport_config("localhost", first_driver_server.port, verify_full())

      // Act
      let connected = try(config, connect_with_minute_deadline)

      // Assert
      connected
      |> should
      |> be_ok
      |> close_connection
      |> extract_receive_result(timeout: 50)
      |> be_error
      |> be_equal(ReceiveFailed(SocketClosed))
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
    it("reads a TLS alert of the ssl application by its name", fn() {
      // Arrange
      let reason =
        dynamic.array([
          atom.to_dynamic(atom.create("tls_alert")),
          dynamic.array([
            atom.to_dynamic(atom.create("bad_record_mac")),
            dynamic.string("TLS client: Bad Record MAC"),
          ]),
        ])

      // Act
      let failure = socket_failure(reason)

      // Assert
      failure
      |> should
      |> be_equal(TlsAlert(atom.create("bad_record_mac")))
      |> or_fail_with("Expected the alert's name")
    }),
    it("keeps the printed form of a reason of another shape", fn() {
      // Arrange
      let reason = dynamic.array([dynamic.int(1), dynamic.int(2)])

      // Act
      let failure = socket_failure(reason)

      // Assert
      failure
      |> should
      |> be_equal(OtherReason("{1,2}"))
      |> or_fail_with("Expected the printed reason")
    }),
    connect_reason_test(
      ReasonAtom(atom.create("nxdomain")),
      DnsLookupFailed("db"),
    ),
    connect_reason_test(
      TlsAlert(atom.create("bad_record_mac")),
      ConnectUnlisted("bad_record_mac"),
    ),
    connect_reason_test(
      OtherReason("{some,reason}"),
      ConnectUnlisted("{some,reason}"),
    ),
    connect_reason_test(ReasonAtom(atom.create("enotconn")), ConnectClosed),
    connect_reason_test(ReasonAtom(atom.create("einval")), ConnectClosed),
    connect_reason_test(
      ReasonAtom(atom.create("ehostunreach")),
      ConnectUnlisted("ehostunreach"),
    ),
    socket_reason_test(ReasonAtom(atom.create("einval")), SocketClosed),
    socket_reason_test(OtherReason("{some,reason}"), Unlisted("{some,reason}")),
    connect_reason_test(ReasonAtom(atom.create("timeout")), ConnectTimedOut),
    connect_reason_test(ReasonAtom(atom.create("econnrefused")), ConnectRefused),
    socket_reason_test(ReasonAtom(atom.create("closed")), SocketClosed),
    socket_reason_test(ReasonAtom(atom.create("enotconn")), SocketClosed),
    socket_reason_test(ReasonAtom(atom.create("econnreset")), ConnectionReset),
    socket_reason_test(
      ReasonAtom(atom.create("ehostunreach")),
      Unlisted("ehostunreach"),
    ),
  ]
}

fn connect_reason_test(reason: SocketFailure, expected: TransportError) {
  it("maps the reason " <> inspect(reason) <> " of a connect", fn() {
    // Act
    let error = connect_error(reason, "db")

    // Assert
    error
    |> should
    |> be_equal(expected)
    |> or_fail_with("Expected the typed error")
  })
}

fn socket_reason_test(reason: SocketFailure, expected: SocketError) {
  it("maps the reason " <> inspect(reason) <> " of a socket call", fn() {
    // Act
    let error = socket_error(reason)

    // Assert
    error
    |> should
    |> be_equal(expected)
    |> or_fail_with("Expected the typed error")
  })
}
