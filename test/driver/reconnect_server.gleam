//// A fake server that lets a connection log in once, ends the session,
//// and then behaves badly on the reconnect (see
//// `driver_reconnect_server_ffi.erl`), for the tests of the setup
//// deadline on a reconnect.

import dream_postgres/driver/connection.{
  type Connection, type ConnectionEvent, type DriverError, Backoff,
  ConnectionConfig,
}
import dream_test/context.{type Context}
import driver/server_connection.{
  connection_config, next_event, start_configured, stop_connection,
}
import gleam/erlang/process.{type Subject}
import gleam/option.{Some}
import gleam/result.{map_error, try}

/// What the fake server does on the second connection.
pub type SecondConnection {
  /// It sends nothing.
  Silent
  /// It sends `head`, then one byte each `interval_milliseconds`, so the
  /// message never ends.
  Trickle(head: BitArray, interval_milliseconds: Int)
}

/// A running reconnect server.
pub type ReconnectServer

@external(erlang, "driver_reconnect_server_ffi", "start")
fn start_ffi(
  second: SecondConnection,
) -> Result(#(Int, ReconnectServer), String)

@external(erlang, "driver_reconnect_server_ffi", "wait_for_second_connection")
fn wait_for_second_connection(server: ReconnectServer) -> Result(Nil, String)

/// What a reconnect against the fake server gave.
pub type BadReconnect {
  BadReconnect(
    connection: Connection,
    /// The first two events: the loss of the first session, and the end
    /// of the reconnect.
    events: List(ConnectionEvent),
    /// The answer of a request that came while the reconnect ran.
    waiting_answer: Result(Nil, DriverError),
  )
}

/// A context setup whose act starts a connection with a setup timeout of
/// `setup_timeout` milliseconds against the fake server, waits until the
/// reconnect is on the second connection, sends a request, and takes the
/// first two events. The teardown stops the connection.
pub fn bad_reconnect_setup(
  second: SecondConnection,
  setup_timeout: Int,
) -> Context(BadReconnect) {
  context.setup(
    setup: fn() { reconnect_badly(second, setup_timeout) },
    teardown: stop_bad_reconnect,
  )
}

fn reconnect_badly(
  second: SecondConnection,
  setup_timeout: Int,
) -> Result(BadReconnect, String) {
  use #(port, server) <- try(start_ffi(second))
  use config <- try(connection_config(port))
  let events = process.new_subject()
  use connection <- try(start_configured(
    ConnectionConfig(
      ..config,
      setup_timeout_milliseconds: setup_timeout,
      reconnect: Backoff(10, 60_000),
      events: Some(events),
    ),
  ))
  watch_reconnect(connection, server, events)
  |> map_error(fn(error) {
    connection.stop(connection)
    error
  })
}

fn watch_reconnect(
  connection: Connection,
  server: ReconnectServer,
  events: Subject(ConnectionEvent),
) -> Result(BadReconnect, String) {
  use Nil <- try(wait_for_second_connection(server))
  let waiting_answer =
    connection.run_script(connection, "SELECT 1", 5000)
    |> result.replace(Nil)
  use lost <- try(next_event(events) |> map_error(no_event))
  use reconnect_end <- try(next_event(events) |> map_error(no_event))
  Ok(BadReconnect(connection:, events: [lost, reconnect_end], waiting_answer:))
}

fn no_event(_nothing: Nil) -> String {
  "no event within 5 seconds"
}

fn stop_bad_reconnect(outcome: BadReconnect) -> Result(Nil, String) {
  stop_connection(outcome.connection)
}
