//// Proves a supervised connection whose server is down when it starts: it
//// stays up, refuses requests with `NotConnected`, and connects once the
//// server listens.

import dream_postgres/driver/connection.{
  type Connection, type ConnectionEvent, type DriverError, Backoff,
  ConnectFailed, Connected, ConnectionConfig, NotConnected, TransportRefused,
  supervised,
}
import dream_postgres/driver/transport.{ConnectRefused}
import dream_test/context.{type Context}
import dream_test/matchers.{be_equal, be_error, be_ok, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit_context.{describe, it}
import driver/fake_server.{free_port}
import driver/reconnect_server.{
  next_event_after_failed_connects, start_forwarder,
}
import driver/server_connection.{connection_config, next_event, stop_connection}
import driver/servers.{first_driver_server}
import gleam/erlang/process
import gleam/option.{Some}
import gleam/result.{map_error, replace, try}
import gleam/string.{inspect}

/// The tests of a supervised connection that starts with its server down.
pub fn tests() -> TestSuite {
  describe("a supervised connection whose server is down", late_server_setup(), [
    it("tells ConnectFailed for its first attempt", fn(outcome: LateServer) {
      // Assert
      outcome.first_event
      |> should
      |> be_equal(Ok(ConnectFailed(TransportRefused(ConnectRefused))))
      |> or_fail_with("Expected ConnectFailed")
    }),
    it(
      "refuses a request with NotConnected before its first login",
      fn(outcome: LateServer) {
        // Assert
        outcome.early_request
        |> should
        |> be_error
        |> be_equal(NotConnected(TransportRefused(ConnectRefused)))
        |> or_fail_with("Expected NotConnected")
      },
    ),
    it("tells Connected once the server listens", fn(outcome: LateServer) {
      // Assert
      outcome.connected_event
      |> should
      |> be_equal(Ok(Connected))
      |> or_fail_with("Expected Connected")
    }),
    it("runs a request after its first login", fn(outcome: LateServer) {
      // Assert
      outcome.late_request
      |> should
      |> be_ok
      |> or_fail_with("Expected the request to run")
    }),
  ])
}

/// What a supervised connection did before and after its server listened.
type LateServer {
  LateServer(
    connection: Connection,
    first_event: Result(ConnectionEvent, Nil),
    early_request: Result(Nil, DriverError),
    connected_event: Result(ConnectionEvent, Nil),
    late_request: Result(Nil, DriverError),
  )
}

fn late_server_setup() -> Context(LateServer) {
  context.setup(setup: start_before_server, teardown: stop_late_server)
}

fn start_before_server() -> Result(LateServer, String) {
  let port = free_port()
  let events = process.new_subject()
  use config <- try(connection_config(port))
  let config =
    ConnectionConfig(
      ..config,
      reconnect: Backoff(10, 100),
      events: Some(events),
    )
  use started <- try(supervised(config).start() |> map_error(inspect))
  watch_late_server(started.data, port, events)
  |> map_error(fn(error) {
    connection.stop(started.data)
    error
  })
}

fn watch_late_server(
  connection: Connection,
  port: Int,
  events: process.Subject(ConnectionEvent),
) -> Result(LateServer, String) {
  let first_event = next_event(events)
  let early_request =
    connection.run_script(connection, "SELECT 1", 5000) |> replace(Nil)
  use Nil <- try(start_forwarder(port, first_driver_server.port))
  let connected_event = next_event_after_failed_connects(events)
  let late_request =
    connection.run_script(connection, "SELECT 1", 5000) |> replace(Nil)
  Ok(LateServer(
    connection:,
    first_event:,
    early_request:,
    connected_event:,
    late_request:,
  ))
}

fn stop_late_server(outcome: LateServer) -> Result(Nil, String) {
  stop_connection(outcome.connection)
}
