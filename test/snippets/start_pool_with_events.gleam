import dream_errors.{type Error}
import dream_postgres/config.{type Config, type PoolEvent, pool_events}
import dream_postgres/error.{type PostgresError}
import dream_postgres/pool.{type Connection, start}
import gleam/erlang/process.{type Subject}

pub fn start_pool_with_events(
  config: Config,
  event_subject: Subject(PoolEvent),
) -> Result(Connection, Error(PostgresError)) {
  config
  |> pool_events(event_subject)
  |> start
}
