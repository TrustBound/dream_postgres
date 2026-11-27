//// Logs in to the driver servers of PostgreSQL 16 to 19 with each login
//// method of `test/docker/driver_pg_hba.conf`, over the transport.

import dream_postgres/driver/login.{
  type ChannelBindingSetting, type LoginOutcome, DisableChannelBinding,
  PreferChannelBinding, RequireChannelBinding, ServerRejectedLogin,
}
import dream_postgres/driver/message.{
  type ProtocolVersion, Protocol30, Protocol32,
}
import dream_postgres/driver/transport.{
  type Tls, AuthorityFile, CheckAuthorityAndHost, NoTls, PostgresNegotiation,
  RequireTls,
}
import dream_postgres/internal/cell.{type TransactionStatus, Idle}
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import driver/server_login.{
  type LoginFailure, type TestLogin, LoginFailed, TestLogin, log_in,
}
import driver/servers.{type Server, driver_servers}
import gleam/int.{to_string}
import gleam/list.{map}
import gleam/result.{map_error}

/// The tests of each login method on each driver server.
pub fn tests() -> TestSuite {
  describe("logging in to real servers", map(driver_servers(), server_tests))
}

fn verify_full() -> Tls {
  RequireTls(
    CheckAuthorityAndHost(AuthorityFile("test/fixtures/ssl/ca.crt")),
    PostgresNegotiation,
  )
}

fn plain(user: String, password: String) -> TestLogin {
  TestLogin(
    host: "localhost",
    tls: NoTls,
    user:,
    password:,
    channel_binding: PreferChannelBinding,
    protocol_version: Protocol30,
  )
}

fn over_tls(user: String, binding: ChannelBindingSetting) -> TestLogin {
  TestLogin(
    ..plain(user, "dream"),
    tls: verify_full(),
    channel_binding: binding,
  )
}

fn server_tests(server: Server) {
  group("PostgreSQL " <> to_string(server.version), [
    it("logs in with trust", fn() {
      check_logged_in(server, plain("dream_trust", ""))
    }),
    it("logs in with a cleartext password", fn() {
      check_logged_in(server, plain("dream_cleartext", "dream"))
    }),
    it("logs in with MD5", fn() {
      check_logged_in(server, plain("dream_md5", "dream"))
    }),
    it("logs in with SCRAM-SHA-256", fn() {
      check_logged_in(server, plain("dream", "dream"))
    }),
    it("logs in with SCRAM-SHA-256 over TLS without channel binding", fn() {
      check_logged_in(server, over_tls("dream", DisableChannelBinding))
    }),
    it("logs in with SCRAM-SHA-256-PLUS when channel binding is required", fn() {
      check_logged_in(server, over_tls("dream_tls", RequireChannelBinding))
    }),
    it("gives 28P01 for a wrong SCRAM password", fn() {
      check_refused(server, plain("dream", "wrong"), "28P01")
    }),
    it("gives 28P01 for a wrong MD5 password", fn() {
      check_refused(server, plain("dream_md5", "wrong"), "28P01")
    }),
    it("gives 28000 for dream_tls without TLS", fn() {
      check_refused(server, plain("dream_tls", "dream"), "28000")
    }),
    it("speaks the newest protocol that it offers when asked for 3.2", fn() {
      check_protocol(server)
    }),
  ])
}

fn check_logged_in(server: Server, test_login: TestLogin) {
  // Act
  let status = log_in(server, test_login) |> result.map(transaction_status)

  // Assert
  status
  |> should
  |> be_equal(Ok(Idle))
  |> or_fail_with("Expected an idle connection after the login")
}

fn check_refused(server: Server, test_login: TestLogin, code: String) {
  // Act
  let refusal =
    log_in(server, test_login)
    |> result.map(transaction_status)
    |> map_error(error_code)

  // Assert
  refusal
  |> should
  |> be_equal(Error(code))
  |> or_fail_with("Expected the SQLSTATE " <> code)
}

/// PostgreSQL 18 and later speak protocol 3.2. PostgreSQL 16 and 17 answer
/// with NegotiateProtocolVersion, and the login goes on with 3.0.
fn check_protocol(server: Server) {
  // Arrange
  let test_login =
    TestLogin(..plain("dream_trust", ""), protocol_version: Protocol32)
  let expected = case server.version >= 18 {
    True -> Protocol32
    False -> Protocol30
  }

  // Act
  let version = log_in(server, test_login) |> result.map(protocol_version)

  // Assert
  version
  |> should
  |> be_equal(Ok(expected))
  |> or_fail_with("Expected the protocol version of the server")
}

fn transaction_status(outcome: LoginOutcome) -> TransactionStatus {
  outcome.transaction_status
}

fn protocol_version(outcome: LoginOutcome) -> ProtocolVersion {
  outcome.protocol_version
}

fn error_code(failure: LoginFailure) -> String {
  case failure {
    LoginFailed(ServerRejectedLogin(report)) -> report.code
    _ -> "not a server refusal"
  }
}
