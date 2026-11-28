//// Proves the one deadline of a setup: the deadline itself, a transport
//// step that it cuts short, and a reconnect that it ends.

import dream_postgres/driver/connection.{start_failure}
import dream_postgres/driver/connection/event.{
  ConnectionLost, Disconnected, ReconnectFailed, SetupExited, SetupTimedOut,
  SocketFailed,
}
import dream_postgres/driver/connection/request_failure.{
  ConnectionEnded, SimpleQueryRequestFailed,
}
import dream_postgres/driver/connection/settings.{ConnectionConfig}
import dream_postgres/driver/deadline.{
  bounded_wait, from_now, has_passed, time_left,
}
import dream_postgres/driver/transport.{
  ConnectTimedOut, NoCertificateCheck, PostgresNegotiation, RequireTls,
  SocketClosed, TransportConfig,
}
import dream_test/matchers.{
  be_equal, be_error, be_false, be_ok, be_true, or_fail_with, should,
}
import dream_test/suite.{type TestSuite}
import dream_test/unit
import dream_test/unit_context
import driver/fake_server.{start_silent_server}
import driver/reconnect_server.{
  type BadReconnect, Silent, Trickle, bad_reconnect_setup, kill_linked_process,
  linked_process, monitor_count, monitored_by_count, start_watched_silent_server,
  wait_for_connection,
}
import driver/server_connection.{connection_config}
import driver/servers.{first_driver_server}
import gleam/bool
import gleam/erlang/process
import gleam/otp/actor
import gleam/result.{map_error, try}
import gleam/string.{inspect}

/// The tests of the setup deadline.
pub fn tests() -> TestSuite {
  suite.group("the setup deadline", [
    deadline_tests(),
    start_failure_tests(),
    start_tests(),
    start_monitor_tests(),
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

fn start_failure_tests() -> TestSuite {
  unit.describe("a process that did not start", [
    unit.it("gives SetupTimedOut when the VM did not run it in time", fn() {
      // Act
      let error = start_failure(actor.InitTimeout)

      // Assert
      error
      |> should
      |> be_equal(SetupTimedOut)
      |> or_fail_with("Expected SetupTimedOut")
    }),
    unit.it("gives SetupExited when its start failed", fn() {
      // Act
      let error = start_failure(actor.InitFailed("no start"))

      // Assert
      error
      |> should
      |> be_equal(SetupExited)
      |> or_fail_with("Expected SetupExited")
    }),
    unit.it("gives SetupExited when it exited while it started", fn() {
      // Act
      let error = start_failure(actor.InitExited(process.Normal))

      // Assert
      error
      |> should
      |> be_equal(SetupExited)
      |> or_fail_with("Expected SetupExited")
    }),
  ])
}

fn start_tests() -> TestSuite {
  unit.describe("a start", [
    unit.it("gives SetupExited when the process ends during its open", fn() {
      // Act
      let started = {
        use #(port, server) <- try(start_watched_silent_server())
        use config <- try(connection_config(port))
        let answers = process.new_subject()
        let starter =
          process.spawn_unlinked(fn() {
            process.trap_exits(True)
            process.send(answers, connection.start(config))
          })
        use Nil <- try(wait_for_connection(server))
        use Nil <- try(kill_linked_process(starter))
        process.receive(answers, 5000)
        |> result.replace_error("no answer of the start")
      }

      // Assert
      started
      |> should
      |> be_ok
      |> be_error
      |> be_equal(SetupExited)
      |> or_fail_with("Expected SetupExited")
    }),
  ])
}

fn start_monitor_tests() -> TestSuite {
  unit.describe("the wait of a start", [
    unit.it("leaves no monitor after a start that worked", fn() {
      // Act
      let monitors = {
        use config <- try(connection_config(first_driver_server.port))
        let answers = process.new_subject()
        process.spawn_unlinked(fn() {
          let count = {
            use connection <- try(
              connection.start(config) |> map_error(inspect),
            )
            let count = monitor_count(process.self())
            connection.stop(connection)
            count
          }
          process.send(answers, count)
        })
        process.receive(answers, 5000)
        |> result.replace_error("no count")
        |> result.flatten
      }

      // Assert
      monitors
      |> should
      |> be_equal(Ok(0))
      |> or_fail_with("Expected no monitor left in the starter")
    }),
    unit.it("leaves no monitor after a start that failed", fn() {
      // Act
      let monitors = {
        use port <- try(start_silent_server())
        use config <- try(connection_config(port))
        let config = ConnectionConfig(..config, setup_timeout_milliseconds: 100)
        let answers = process.new_subject()
        process.spawn_unlinked(fn() {
          let worked = connection.start(config) |> result.is_ok
          process.send(
            answers,
            bool.guard(
              when: worked,
              return: Error("the start worked"),
              otherwise: fn() { monitor_count(process.self()) },
            ),
          )
        })
        process.receive(answers, 5000)
        |> result.replace_error("no count")
        |> result.flatten
      }

      // Assert
      monitors
      |> should
      |> be_equal(Ok(0))
      |> or_fail_with("Expected no monitor left in the starter")
    }),
    unit.it("leaves no monitor on the process after its starter died", fn() {
      // Act
      let monitors = {
        use #(port, server) <- try(start_watched_silent_server())
        use config <- try(connection_config(port))
        let config = ConnectionConfig(..config, setup_timeout_milliseconds: 300)
        let starter = process.spawn_unlinked(fn() { connection.start(config) })
        use Nil <- try(wait_for_connection(server))
        use connection_pid <- try(linked_process(starter))
        let starter_monitor = process.monitor(starter)
        process.kill(starter)
        use _down <- try(
          process.new_selector()
          |> process.select_specific_monitor(starter_monitor, fn(down) { down })
          |> process.selector_receive(5000)
          |> result.replace_error("the starter did not end"),
        )
        monitored_by_count(connection_pid)
      }

      // Assert
      monitors
      |> should
      |> be_equal(Ok(0))
      |> or_fail_with("Expected no monitor left on the connection process")
    }),
  ])
}

fn transport_tests() -> TestSuite {
  unit.describe("a transport connect", [
    unit.it("gives SetupTimedOut when the TLS answer outlasts the setup", fn() {
      // Arrange
      let tls = RequireTls(NoCertificateCheck, PostgresNegotiation)

      // Act
      let started = {
        use port <- try(start_silent_server())
        use config <- try(connection_config(port))
        let transport =
          TransportConfig(
            ..config.transport,
            tls:,
            connect_timeout_milliseconds: 60_000,
          )
        Ok(connection.start(
          ConnectionConfig(
            ..config,
            transport:,
            setup_timeout_milliseconds: 100,
          ),
        ))
      }

      // Assert
      started
      |> should
      |> be_ok
      |> be_error
      |> be_equal(SetupTimedOut)
      |> or_fail_with("Expected SetupTimedOut at the end of the setup")
    }),
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
      |> be_equal(Ok(Error(ConnectTimedOut)))
      |> or_fail_with("Expected ConnectTimedOut at the deadline")
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
          Disconnected(ConnectionLost(SocketFailed(SocketClosed))),
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
        |> be_equal(
          SimpleQueryRequestFailed(
            ConnectionEnded(ConnectionLost(SocketFailed(SocketClosed))),
          ),
        )
        |> or_fail_with("Expected the loss as the answer, after the reconnect")
      },
    ),
  ])
}
