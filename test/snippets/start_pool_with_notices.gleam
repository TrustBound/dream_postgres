import dream_errors.{type Error}
import dream_postgres/config.{type Config, type ServerNotice, notices}
import dream_postgres/error.{type PostgresError}
import dream_postgres/pool.{type Connection, start_pool}
import gleam/erlang/process.{type Subject}

pub fn start_pool_with_notices(
  config: Config,
  notice_subject: Subject(ServerNotice),
) -> Result(Connection, Error(PostgresError)) {
  config
  |> notices(notice_subject)
  |> start_pool
}
