import dream_errors.{type Error}
import dream_postgres.{
  type Config, type Connection, type PoolEvent, type PostgresError,
  ConnectFailed, Connected, Disconnected, Free, Held, Reconnected, Refused,
  Replacing, Returned, Stopping, Waiting, pool_events, start,
}
import dream_postgres/error.{describe}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/pair
import gleam/result

/// Starts a pool that sends each event of the pool to a new subject of
/// the calling process.
pub fn start_with_pool_events(
  config: Config,
) -> Result(#(Connection, Subject(PoolEvent)), Error(PostgresError)) {
  let event_subject = process.new_subject()
  config
  |> pool_events(event_subject)
  |> start
  |> result.map(pair.new(_, event_subject))
}

/// The text of a pool event for a log line.
pub fn event_line(event: PoolEvent) -> String {
  case event {
    Connected(slot:) -> slot_text(slot) <> " connected"
    Disconnected(slot:, reason:) ->
      slot_text(slot) <> " lost its session: " <> describe(reason)
    Reconnected(slot:) -> slot_text(slot) <> " connected again"
    ConnectFailed(slot:, error: failure) ->
      slot_text(slot) <> " did not connect: " <> describe(failure)
    Replacing(slot:) -> slot_text(slot) <> " is replaced"
    Free(slot:) -> slot_text(slot) <> " is free"
    Held(slot:) -> slot_text(slot) <> " is held"
    Returned(slot:) -> slot_text(slot) <> " came back"
    Waiting(count:) -> int.to_string(count) <> " calls wait for a connection"
    Refused(error: failure) -> "a call got no connection: " <> describe(failure)
    Stopping -> "the pool stops"
  }
}

fn slot_text(slot: Int) -> String {
  "connection " <> int.to_string(slot)
}
