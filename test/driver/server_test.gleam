//// Proves the driver servers of `docker-compose.yml` before the driver has
//// any code of its own. Each test opens a plain TCP connection to one
//// server, sends one message whose bytes the test writes by hand (PostgreSQL
//// documentation, "Message Formats") and checks the first answer:
////
//// - an SSLRequest gets `S`, so the server has SSL on;
//// - a StartupMessage for each database user gets the login request of that
////   user's method, so `test/docker/driver_pg_hba.conf` is in force.

import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import driver/servers.{type Server, database, driver_servers}
import gleam/bit_array.{byte_size}
import gleam/int.{to_string}
import gleam/list.{map}

@external(erlang, "driver_socket_ffi", "ssl_answer")
fn ssl_answer(port: Int, request: BitArray) -> Result(BitArray, String)

@external(erlang, "driver_socket_ffi", "first_message")
fn first_message(port: Int, request: BitArray) -> Result(BitArray, String)

/// The tests of every driver server.
pub fn tests() -> TestSuite {
  describe("the driver test servers", map(driver_servers(), server_tests))
}

fn server_tests(server: Server) {
  group("PostgreSQL " <> to_string(server.version), [
    it("answers an SSLRequest with S", fn() { check_ssl_answer(server) }),
    it("lets dream_trust in with no password", fn() {
      check_login_request(server, "dream_trust", 0)
    }),
    it("asks dream_cleartext for a cleartext password", fn() {
      check_login_request(server, "dream_cleartext", 3)
    }),
    it("asks dream_md5 for an MD5 password", fn() {
      check_login_request(server, "dream_md5", 5)
    }),
    it("asks dream for SASL", fn() { check_login_request(server, "dream", 10) }),
    it("refuses dream_tls without TLS", fn() { check_refused(server) }),
  ])
}

fn check_ssl_answer(server: Server) {
  // Arrange
  let request = <<8:32, 1234:16, 5679:16>>

  // Act
  let answer = ssl_answer(server.port, request)

  // Assert
  answer
  |> should
  |> be_equal(Ok(<<"S">>))
  |> or_fail_with("Expected S for an SSLRequest")
}

fn check_login_request(server: Server, user: String, expected_code: Int) {
  // Arrange
  let request = startup_message(user)

  // Act
  let answer = first_message(server.port, request)

  // Assert
  login_request_code(answer)
  |> should
  |> be_equal(Ok(expected_code))
  |> or_fail_with("Expected login request " <> to_string(expected_code))
}

fn check_refused(server: Server) {
  // Arrange
  let request = startup_message("dream_tls")

  // Act
  let answer = first_message(server.port, request)

  // Assert
  message_type(answer)
  |> should
  |> be_equal(Ok(<<"E">>))
  |> or_fail_with("Expected an ErrorResponse for dream_tls without TLS")
}

/// A StartupMessage of protocol 3.0 for the user, to the test database.
fn startup_message(user: String) -> BitArray {
  let parameters = <<
    "user":utf8, 0, user:utf8, 0, "database":utf8, 0, database:utf8, 0, 0,
  >>
  let length = 8 + byte_size(parameters)
  <<length:32, 3:16, 0:16, parameters:bits>>
}

/// The code of an Authentication message: 0 for AuthenticationOk, 3 for a
/// cleartext password, 5 for MD5, 10 for SASL.
fn login_request_code(answer: Result(BitArray, String)) -> Result(Int, String) {
  case answer {
    Ok(<<"R", _length:32, code:32, _rest:bits>>) -> Ok(code)
    Ok(_other) -> Error("not an Authentication message")
    Error(reason) -> Error(reason)
  }
}

fn message_type(answer: Result(BitArray, String)) -> Result(BitArray, String) {
  case answer {
    Ok(<<type_byte:bytes-size(1), _rest:bits>>) -> Ok(type_byte)
    Ok(_other) -> Error("an empty answer")
    Error(reason) -> Error(reason)
  }
}
