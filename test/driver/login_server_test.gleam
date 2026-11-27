//// Logs in to the driver servers of PostgreSQL 16 to 19 with each login
//// method of `test/docker/driver_pg_hba.conf`, over the transport.

import dream_postgres/driver/login.{
  type ChannelBindingSetting, DisableChannelBinding, PreferChannelBinding,
  RequireChannelBinding,
}
import dream_postgres/driver/message.{Protocol30, Protocol32}
import dream_postgres/driver/transport.{NoTls}
import dream_postgres/internal/cell.{Idle}
import dream_test/matchers.{be_equal, be_error, be_ok, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import driver/server_login.{type TestLogin, TestLogin, log_in, log_in_with_nonce}
import driver/servers.{type Server, driver_servers}
import fixtures/driver_tls.{verify_full}
import gleam/int.{to_string}
import gleam/list.{map}
import matchers/extract_protocol_version.{extract_protocol_version}
import matchers/extract_rejected_login_code.{extract_rejected_login_code}
import matchers/extract_transaction_status.{extract_transaction_status}

/// The tests of each login method on each driver server.
pub fn tests() -> TestSuite {
  describe("logging in to real servers", map(driver_servers(), server_tests))
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
      // Arrange
      let test_login = plain("dream_trust", "")

      // Act
      let outcome = log_in(server, test_login)

      // Assert
      outcome
      |> should
      |> be_ok
      |> extract_transaction_status
      |> be_equal(Idle)
      |> or_fail_with("Expected an idle connection after the login")
    }),
    it("logs in with a cleartext password", fn() {
      // Arrange
      let test_login = plain("dream_cleartext", "dream")

      // Act
      let outcome = log_in(server, test_login)

      // Assert
      outcome
      |> should
      |> be_ok
      |> extract_transaction_status
      |> be_equal(Idle)
      |> or_fail_with("Expected an idle connection after the login")
    }),
    it("logs in with MD5", fn() {
      // Arrange
      let test_login = plain("dream_md5", "dream")

      // Act
      let outcome = log_in(server, test_login)

      // Assert
      outcome
      |> should
      |> be_ok
      |> extract_transaction_status
      |> be_equal(Idle)
      |> or_fail_with("Expected an idle connection after the login")
    }),
    it("logs in with SCRAM-SHA-256", fn() {
      // Arrange
      let test_login = plain("dream", "dream")

      // Act
      let outcome = log_in(server, test_login)

      // Assert
      outcome
      |> should
      |> be_ok
      |> extract_transaction_status
      |> be_equal(Idle)
      |> or_fail_with("Expected an idle connection after the login")
    }),
    it("logs in with SCRAM-SHA-256 over TLS without channel binding", fn() {
      // Arrange
      let test_login = over_tls("dream", DisableChannelBinding)

      // Act
      let outcome = log_in(server, test_login)

      // Assert
      outcome
      |> should
      |> be_ok
      |> extract_transaction_status
      |> be_equal(Idle)
      |> or_fail_with("Expected an idle connection after the login")
    }),
    it("logs in with SCRAM-SHA-256-PLUS when channel binding is required", fn() {
      // Arrange
      let test_login = over_tls("dream_tls", RequireChannelBinding)

      // Act
      let outcome = log_in(server, test_login)

      // Assert
      outcome
      |> should
      |> be_ok
      |> extract_transaction_status
      |> be_equal(Idle)
      |> or_fail_with("Expected an idle connection after the login")
    }),
    it("logs in with SCRAM-SHA-256 and a client nonce of 618 bytes", fn() {
      // Arrange
      let test_login = plain("dream", "dream")

      // Act
      let outcome = log_in_with_nonce(server, test_login, <<0:size(4944)>>)

      // Assert
      outcome
      |> should
      |> be_ok
      |> extract_transaction_status
      |> be_equal(Idle)
      |> or_fail_with("Expected an idle connection after the login")
    }),
    it("logs in with SCRAM-SHA-256-PLUS and a client nonce of 618 bytes", fn() {
      // Arrange
      let test_login = over_tls("dream_tls", RequireChannelBinding)

      // Act
      let outcome = log_in_with_nonce(server, test_login, <<0:size(4944)>>)

      // Assert
      outcome
      |> should
      |> be_ok
      |> extract_transaction_status
      |> be_equal(Idle)
      |> or_fail_with("Expected an idle connection after the login")
    }),
    it("gives 28P01 for a wrong SCRAM password", fn() {
      // Arrange
      let test_login = plain("dream", "wrong")

      // Act
      let outcome = log_in(server, test_login)

      // Assert
      outcome
      |> should
      |> be_error
      |> extract_rejected_login_code
      |> be_equal("28P01")
      |> or_fail_with("Expected the SQLSTATE 28P01")
    }),
    it("gives 28P01 for a wrong MD5 password", fn() {
      // Arrange
      let test_login = plain("dream_md5", "wrong")

      // Act
      let outcome = log_in(server, test_login)

      // Assert
      outcome
      |> should
      |> be_error
      |> extract_rejected_login_code
      |> be_equal("28P01")
      |> or_fail_with("Expected the SQLSTATE 28P01")
    }),
    it("gives 28000 for dream_tls without TLS", fn() {
      // Arrange
      let test_login = plain("dream_tls", "dream")

      // Act
      let outcome = log_in(server, test_login)

      // Assert
      outcome
      |> should
      |> be_error
      |> extract_rejected_login_code
      |> be_equal("28000")
      |> or_fail_with("Expected the SQLSTATE 28000")
    }),
    protocol_test(server),
  ])
}

/// PostgreSQL 18 and later speak protocol 3.2. PostgreSQL 16 and 17 answer
/// with NegotiateProtocolVersion, and the login goes on with 3.0.
fn protocol_test(server: Server) {
  let expected = case server.version >= 18 {
    True -> Protocol32
    False -> Protocol30
  }
  it("speaks the newest protocol that it offers when asked for 3.2", fn() {
    // Arrange
    let test_login =
      TestLogin(..plain("dream_trust", ""), protocol_version: Protocol32)

    // Act
    let outcome = log_in(server, test_login)

    // Assert
    outcome
    |> should
    |> be_ok
    |> extract_protocol_version
    |> be_equal(expected)
    |> or_fail_with("Expected the protocol version of the server")
  })
}
