//// Proves the driver servers of `docker-compose.yml` before the driver has
//// any code of its own. Each test opens a plain TCP connection to one
//// server, sends one message whose bytes the test writes by hand (PostgreSQL
//// documentation, "Message Formats") and checks the first answer:
////
//// - an SSLRequest gets `S`, so the server has SSL on;
//// - a StartupMessage for each database user gets the login request of that
////   user's method, so `test/docker/driver_pg_hba.conf` is in force.

import dream_test/matchers.{be_equal, be_ok, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import driver/servers.{type Server, database, driver_servers}
import gleam/bit_array.{byte_size}
import gleam/int.{to_string}
import gleam/list.{map}
import matchers/extract_authentication_code.{extract_authentication_code}
import matchers/extract_message_type.{extract_message_type}

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
    it("answers an SSLRequest with S", fn() {
      // Arrange
      let request = <<8:32, 1234:16, 5679:16>>

      // Act
      let answer = ssl_answer(server.port, request)

      // Assert
      answer
      |> should
      |> be_ok
      |> be_equal(<<"S">>)
      |> or_fail_with("Expected S for an SSLRequest")
    }),
    it("lets dream_trust in with no password", fn() {
      // Arrange
      let request = startup_message("dream_trust")

      // Act
      let answer = first_message(server.port, request)

      // Assert
      answer
      |> should
      |> be_ok
      |> extract_authentication_code
      |> be_equal(0)
      |> or_fail_with("Expected login request 0")
    }),
    it("asks dream_cleartext for a cleartext password", fn() {
      // Arrange
      let request = startup_message("dream_cleartext")

      // Act
      let answer = first_message(server.port, request)

      // Assert
      answer
      |> should
      |> be_ok
      |> extract_authentication_code
      |> be_equal(3)
      |> or_fail_with("Expected login request 3")
    }),
    it("asks dream_md5 for an MD5 password", fn() {
      // Arrange
      let request = startup_message("dream_md5")

      // Act
      let answer = first_message(server.port, request)

      // Assert
      answer
      |> should
      |> be_ok
      |> extract_authentication_code
      |> be_equal(5)
      |> or_fail_with("Expected login request 5")
    }),
    it("asks dream for SASL", fn() {
      // Arrange
      let request = startup_message("dream")

      // Act
      let answer = first_message(server.port, request)

      // Assert
      answer
      |> should
      |> be_ok
      |> extract_authentication_code
      |> be_equal(10)
      |> or_fail_with("Expected login request 10")
    }),
    it("refuses dream_tls without TLS", fn() {
      // Arrange
      let request = startup_message("dream_tls")

      // Act
      let answer = first_message(server.port, request)

      // Assert
      answer
      |> should
      |> be_ok
      |> extract_message_type
      |> be_equal(<<"E">>)
      |> or_fail_with("Expected an ErrorResponse for dream_tls without TLS")
    }),
  ])
}

/// A StartupMessage of protocol 3.0 for the user, to the test database.
fn startup_message(user: String) -> BitArray {
  let parameters = <<
    "user":utf8, 0, user:utf8, 0, "database":utf8, 0, database:utf8, 0, 0,
  >>
  let length = 8 + byte_size(parameters)
  <<length:32, 3:16, 0:16, parameters:bits>>
}
