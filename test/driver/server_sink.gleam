//// Test fixtures that start connections and pools whose events, notices
//// and notifications go through the sinks of a test, the subscribe of a
//// sink to a listener, and the waits for what a sink sends.

import dream_postgres/driver/connection.{
  type Connection, type ConnectionEvent, type Notification, ConnectionConfig,
}
import dream_postgres/driver/listener.{
  type Listener, type ListenerMessage, type Subscription, subscribe,
}
import dream_postgres/driver/pool.{
  type Pool, type PoolEvent, MemberFree, MemberHeld, MemberReplacing, PoolConfig,
}
import dream_postgres/driver/sink.{type Sink}
import dream_postgres/internal/cell.{type ServerReport}
import driver/server_connection.{
  connection_config, query_text, run_control_simple_query, start_configured,
}
import driver/server_pool.{
  kill_connection, pool_config, start_pool, wait_for_pool_event,
}
import fixtures/identity_sink.{identity_sink}
import gleam/erlang/process.{type Subject}
import gleam/option.{type Option, Some}
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

/// What a pool of two connections did when one of its connection sinks
/// crashed in its first connection, and the pool replaced that
/// connection.
pub type ReplacedRun(called) {
  ReplacedRun(
    /// The next call of the crashed map after its first one, taken at
    /// once after a `pool.status`: `Error(Nil)` when there was none.
    later_call: Result(called, Nil),
    /// The answers of the two connections after the replacement: the new
    /// one and the other one.
    answers: #(String, String),
  )
}

/// Starts a pool of two connections to localhost on `port` with the
/// connection sinks, and runs `raise` on one connection, so that its map
/// crashes once and tells `witness`. Kills that connection, and waits for
/// the pool to replace it. Then runs `raise` on both connections, the new
/// one and the other one, and takes any later call of the map.
///
/// The order is fixed: the drop reaches the pool before the replacement,
/// and the other connection gets the drop before its reset, which comes
/// before its next hold.
pub fn raise_across_replacement(
  port: Int,
  sinks: ConnectionSinks,
  witness: Subject(called),
  raise: fn(Connection) -> Result(String, String),
) -> Result(ReplacedRun(called), String) {
  use config <- try(connection_config(port))
  let pool_events = process.new_subject()
  let connection =
    ConnectionConfig(
      ..config,
      events: sinks.events,
      notices: sinks.notices,
      notifications: sinks.notifications,
    )
  use pool <- try(
    PoolConfig(
      ..pool_config(connection),
      events: Some(identity_sink(pool_events)),
    )
    |> start_pool(2),
  )
  let run = {
    use _replaced <- try(
      hold_both(pool, fn(first, _second) {
        use _answer <- try(raise(first))
        use _first_call <- try(receive_sent(witness))
        kill_connection(first)
        wait_for_replacing(pool_events)
      }),
    )
    use answers <- try(
      hold_both(pool, fn(first, second) {
        use first_answer <- try(raise(first))
        use second_answer <- try(raise(second))
        Ok(#(first_answer, second_answer))
      }),
    )
    use _status <- try(
      pool.status(pool) |> map_error(fn(error) { inspect(error) }),
    )
    Ok(ReplacedRun(later_call: process.receive(witness, 0), answers:))
  }
  pool.stop(pool, 1000)
  run
}

/// Starts a pool of one connection to localhost on `port` with the
/// connection events sink, whose map crashes once on `Connected` and
/// tells `witness`. Kills the connection, waits for the pool to replace
/// it, and holds the new connection. Then takes any later call of the
/// map.
///
/// The order is fixed: the drop reaches the pool before the replacement,
/// and the member gets the pool's drop before the reset after the hold,
/// whose `MemberFree` the function waits for.
pub fn replace_after_events_crash(
  port: Int,
  events: Sink(ConnectionEvent),
  witness: Subject(called),
) -> Result(Result(called, Nil), String) {
  use config <- try(connection_config(port))
  let pool_events = process.new_subject()
  let connection = ConnectionConfig(..config, events: Some(events))
  use pool <- try(
    PoolConfig(
      ..pool_config(connection),
      events: Some(identity_sink(pool_events)),
    )
    |> start_pool(1),
  )
  let run = {
    use _first_call <- try(receive_sent(witness))
    use _replaced <- try(
      pool.hold(pool, 5000, fn(held) {
        kill_connection(held)
        wait_for_replacing(pool_events)
      })
      |> map_error(fn(error) { "the hold failed: " <> inspect(error) })
      |> result.flatten,
    )
    use _answer <- try(hold_text(pool, "SELECT 'held'"))
    use _held <- try(wait_for_pool_event(pool_events, MemberHeld(0)))
    use _free <- try(wait_for_pool_event(pool_events, MemberFree(0)))
    use _status <- try(
      pool.status(pool) |> map_error(fn(error) { inspect(error) }),
    )
    Ok(process.receive(witness, 0))
  }
  pool.stop(pool, 1000)
  run
}

/// Holds both connections of a pool of two at once, and runs `use_both`
/// on them.
fn hold_both(
  pool: Pool(Nil),
  use_both: fn(Connection, Connection) -> Result(value, String),
) -> Result(value, String) {
  pool.hold(pool, 5000, fn(first) {
    pool.hold(pool, 5000, use_both(first, _))
    |> map_error(fn(error) { "the second hold failed: " <> inspect(error) })
    |> result.flatten
  })
  |> map_error(fn(error) { "the first hold failed: " <> inspect(error) })
  |> result.flatten
}

/// Waits for the next `MemberReplacing` of the pool, and drops the other
/// events.
fn wait_for_replacing(pool_events: Subject(PoolEvent)) -> Result(Nil, String) {
  case process.receive(pool_events, 5000) {
    Ok(MemberReplacing(_slot)) -> Ok(Nil)
    Ok(_other) -> wait_for_replacing(pool_events)
    Error(Nil) -> Error("no MemberReplacing within 5 seconds")
  }
}

/// Runs a statement that makes the server send a warning notice, then
/// gives the answer of a query.
pub fn raise_notice(connection: Connection) -> Result(String, String) {
  use _ran <- try(run_control_simple_query(
    connection,
    "DO $$BEGIN RAISE WARNING 'through a pool sink'; END$$",
  ))
  query_text(connection, "SELECT 'answered'")
}

/// Makes the connection's session notify itself, then gives the answer of
/// a query.
pub fn raise_notification(connection: Connection) -> Result(String, String) {
  use _notified <- try(notify_self(connection, "pool_sink", "through a pool"))
  query_text(connection, "SELECT 'answered'")
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
  run_control_simple_query(
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
