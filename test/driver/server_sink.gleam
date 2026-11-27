//// Test fixtures that start connections and pools whose events, notices
//// and notifications go through the sinks of a test, the subscribe of a
//// sink to a listener, and the waits for what a sink sends.

import dream_postgres/driver/connection.{
  type Connection, type ConnectionEvent, type Notification, ConnectionConfig,
}
import dream_postgres/driver/listener.{
  type Listener, type ListenerMessage, type Subscription, subscribe,
}
import dream_postgres/driver/pool.{type Pool, type PoolEvent, PoolConfig}
import dream_postgres/driver/sink.{type Sink}
import dream_postgres/internal/cell.{type ServerReport}
import driver/server_connection.{
  connection_config, query_text, run_control_script, start_configured,
}
import driver/server_pool.{pool_config, start_pool}
import gleam/erlang/process.{type Subject}
import gleam/option.{type Option}
import gleam/result.{map_error, try}
import gleam/string.{inspect}

/// The sinks of one connection.
pub type ConnectionSinks {
  ConnectionSinks(
    events: Option(Sink(ConnectionEvent)),
    notices: Option(Sink(ServerReport)),
    notifications: Option(Sink(Notification)),
  )
}

/// Starts a connection to localhost on `port` with the sinks.
pub fn start_sunk_connection(
  port: Int,
  sinks: ConnectionSinks,
) -> Result(Connection, String) {
  use config <- try(connection_config(port))
  ConnectionConfig(
    ..config,
    events: sinks.events,
    notices: sinks.notices,
    notifications: sinks.notifications,
  )
  |> start_configured
}

/// Starts a pool of one connection to localhost on `port`, with the pool
/// events sink and the connection events sink.
pub fn start_sunk_pool(
  port: Int,
  pool_events: Option(Sink(PoolEvent)),
  connection_events: Option(Sink(ConnectionEvent)),
) -> Result(Pool(Nil), String) {
  use config <- try(connection_config(port))
  let connection = ConnectionConfig(..config, events: connection_events)
  PoolConfig(..pool_config(connection), events: pool_events)
  |> start_pool(1)
}

/// Runs `sql` on a connection of the pool, and gives the one text value of
/// its result.
pub fn hold_text(pool: Pool(Nil), sql: String) -> Result(String, String) {
  pool.hold(pool, 5000, query_text(_, sql))
  |> map_error(fn(error) { "the hold failed: " <> inspect(error) })
  |> result.flatten
}

/// Makes the connection's session listen on `channel`, then notify it with
/// `payload`, so the session gets its own notification.
pub fn notify_self(
  connection: Connection,
  channel: String,
  payload: String,
) -> Result(Nil, String) {
  run_control_script(
    connection,
    "LISTEN " <> channel <> "; NOTIFY " <> channel <> ", '" <> payload <> "'",
  )
}

/// The next message of `subject`, or an error after 5 seconds.
pub fn receive_sent(subject: Subject(message)) -> Result(message, String) {
  process.receive(subject, 5000)
  |> map_error(fn(_timeout) { "no message within 5 seconds" })
}

/// Subscribes the sink to `channel`.
pub fn subscribe_sink(
  listener: Listener,
  channel: String,
  subscriber: Sink(ListenerMessage),
) -> Result(Subscription, String) {
  subscribe(listener, channel, subscriber)
  |> map_error(fn(error) {
    "could not subscribe to " <> channel <> ": " <> inspect(error)
  })
}
