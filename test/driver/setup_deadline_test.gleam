//// Proves the one deadline of a setup: the deadline itself, a transport
//// step that it cuts short, and a reconnect that it ends.

import dream_postgres/driver/connection.{
  ConnectionLost, Disconnected, ReconnectFailed, SetupTimedOut,
}
import dream_postgres/driver/deadline.{
  bounded_wait, from_now, has_passed, time_left,
}
import dream_postgres/driver/transport.{
  NoCertificateCheck, PostgresNegotiation, ReceiveTimedOut, RequireTls,
  SocketClosed, TransportConfig,
}
import dream_test/matchers.{
  be_equal, be_error, be_false, be_true, or_fail_with, should,
}
import dream_test/suite.{type TestSuite}
import dream_test/unit
import dream_test/unit_context
import driver/fake_server.{start_silent_server}
import driver/reconnect_server.{
  type BadReconnect, Silent, Trickle, bad_reconnect_setup,
}
import driver/server_connection.{connection_config}
import gleam/result.{try}

/// The tests of the setup deadline.
pub fn tests() -> TestSuite {
  suite.group("the setup deadline", [
    deadline_tests(),
    transport_tests(),
    reconnect_tests("a reconnect against a silent server", Silent),
    reconnect_tests(
      "a reconnect against a server that sends a byte at a time",
      Trickle(head: <<"S", 1_000_000:32>>, interval_milliseconds: 20),
    ),
  ])
}

fn deadline_tests() -> TestSuite {
  unit.describe("a deadline", [
    unit.it("has passed when it is now", fn() {
      // Act
      let passed = has_passed(from_now(0))

      // Assert
      passed
      |> should
      |> be_true
      |> or_fail_with("Expected a deadline of now to have passed")
    }),
    unit.it("has not passed when it is a minute away", fn() {
      // Act
      let passed = has_passed(from_now(60_000))

      // Assert
      passed
      |> should
      |> be_false
      |> or_fail_with("Expected a deadline a minute away not to have passed")
    }),
    unit.it("leaves no time when it is in the past", fn() {
      // Act
      let left = time_left(from_now(-5))

      // Assert
      left
      |> should
      |> be_equal(0)
      |> or_fail_with("Expected 0 milliseconds left")
    }),
    unit.it("lets a step wait its own timeout when more time is left", fn() {
      // Act
      let wait = bounded_wait(from_now(60_000), 100)

      // Assert
      wait
      |> should
      |> be_equal(100)
      |> or_fail_with("Expected the step's own 100 milliseconds")
    }),
    unit.it("cuts the wait of a step to the time that is left", fn() {
      // Act
      let wait = bounded_wait(from_now(0), 100)

      // Assert
      wait
      |> should
      |> be_equal(0)
      |> or_fail_with("Expected no wait once the deadline passed")
    }),
  ])
}

fn transport_tests() -> TestSuite {
  unit.describe("a transport connect", [
    unit.it("ends the wait for the TLS answer at the deadline", fn() {
      // Arrange
      let tls = RequireTls(NoCertificateCheck, PostgresNegotiation)

      // Act
      let connected = {
        use port <- try(start_silent_server())
        use config <- try(connection_config(port))
        let transport_config =
          TransportConfig(
            ..config.transport,
            tls:,
            connect_timeout_milliseconds: 60_000,
          )
        Ok(transport.connect(transport_config, from_now(100)))
      }

      // Assert
      connected
      |> should
      |> be_equal(Ok(Error(ReceiveTimedOut)))
      |> or_fail_with("Expected ReceiveTimedOut at the deadline")
    }),
  ])
}

fn reconnect_tests(name: String, second: reconnect_server.SecondConnection) {
  unit_context.describe(name, bad_reconnect_setup(second, 200), [
    unit_context.it(
      "ends the reconnect with SetupTimedOut at the deadline",
      fn(outcome: BadReconnect) {
        // Assert
        outcome.events
        |> should
        |> be_equal([
          Disconnected(ConnectionLost(SocketClosed)),
          ReconnectFailed(SetupTimedOut),
        ])
        |> or_fail_with("Expected the loss, then SetupTimedOut")
      },
    ),
    unit_context.it(
      "answers the request that waited behind the reconnect",
      fn(outcome: BadReconnect) {
        // Assert
        outcome.waiting_answer
        |> should
        |> be_error
        |> be_equal(ConnectionLost(SocketClosed))
        |> or_fail_with("Expected the loss as the answer, after the reconnect")
      },
    ),
  ])
}
