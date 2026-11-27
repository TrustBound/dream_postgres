import dream_errors.{type Error}
import dream_postgres.{
  type Config, type Connection, type PoolEvent, type PostgresError, pool_events,
  start,
}
import gleam/erlang/process.{type Subject}

pub fn start_pool_with_events(
  config: Config,
  event_subject: Subject(PoolEvent),
) -> Result(Connection, Error(PostgresError)) {
  config
  |> pool_events(event_subject)
  |> start
}
