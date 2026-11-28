//// A fake server that lets a connection log in once, ends the session,
//// and then behaves badly on the reconnect (see
//// `driver_reconnect_server_ffi.erl`), for the tests of the setup
//// deadline on a reconnect.

import dream_postgres/driver/connection
import dream_postgres/driver/connection/backoff.{Backoff}
import dream_postgres/driver/connection/call.{type Connection}
import dream_postgres/driver/connection/event.{
  type ConnectionEvent, ConnectFailed,
}
import dream_postgres/driver/connection/request_failure.{type SimpleQueryError}
import dream_postgres/driver/connection/settings.{ConnectionConfig}
import dream_postgres/driver/connection/simple_query as connection_simple_query
import dream_postgres/driver/connection/statement as connection_statement
import dream_test/context.{type Context}
import driver/server_connection.{
  connection_config, next_event, start_watched, stop_connection,
}
import fixtures/backoff_strategies.{capped_delay}
import fixtures/identity_sink.{identity_sink}
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

/// A running silent server that tells when it accepted a connection.
pub type SilentServer

/// Starts a server that accepts one connection and never sends a byte,
/// and gives its port.
@external(erlang, "driver_reconnect_server_ffi", "start_silent")
pub fn start_watched_silent_server() -> Result(#(Int, SilentServer), String)

/// Waits until the silent server accepted its connection.
@external(erlang, "driver_reconnect_server_ffi", "wait_for_connection")
pub fn wait_for_connection(server: SilentServer) -> Result(Nil, String)

/// Kills the one process that `pid` links to.
@external(erlang, "driver_reconnect_server_ffi", "kill_linked_process")
pub fn kill_linked_process(pid: process.Pid) -> Result(Nil, String)

/// The one process that `pid` links to.
@external(erlang, "driver_reconnect_server_ffi", "linked_process")
pub fn linked_process(pid: process.Pid) -> Result(process.Pid, String)

/// How many monitors `pid` holds on other processes.
@external(erlang, "driver_reconnect_server_ffi", "monitor_count")
pub fn monitor_count(pid: process.Pid) -> Result(Int, String)

/// How many monitors other processes hold on `pid`.
@external(erlang, "driver_reconnect_server_ffi", "monitored_by_count")
pub fn monitored_by_count(pid: process.Pid) -> Result(Int, String)

/// Listens on `port` and passes the bytes of one client to `server_port`
/// on localhost and back.
@external(erlang, "driver_reconnect_server_ffi", "start_forwarder")
pub fn start_forwarder(port: Int, server_port: Int) -> Result(Nil, String)

/// The next event that is not a `ConnectFailed`.
pub fn next_event_after_failed_connects(
  events: Subject(ConnectionEvent),
) -> Result(ConnectionEvent, Nil) {
  case next_event(events) {
    Ok(ConnectFailed(_error)) -> next_event_after_failed_connects(events)
    other -> other
  }
}

/// What a reconnect against the fake server gave.
pub type BadReconnect {
  BadReconnect(
    connection: Connection,
    /// The first two events: the loss of the first session, and the end
    /// of the reconnect.
    events: List(ConnectionEvent),
    /// The answer of a request that came while the reconnect ran.
    waiting_answer: Result(Nil, SimpleQueryError),
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
  use connection <- try(start_watched(
    ConnectionConfig(
      ..config,
      setup_timeout_milliseconds: setup_timeout,
      reconnect: Backoff(10, 60_000, capped_delay),
      events: Some(identity_sink(events)),
    ),
    events,
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
    connection_simple_query.run_simple_query(
      connection,
      connection_statement.statement("SELECT 1"),
      5000,
    )
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
