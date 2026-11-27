import dream_errors.{type Error}
import dream_postgres.{
  type Config, type Connection, type PostgresError, type ServerNotice, notices,
  start,
}
import gleam/erlang/process.{type Subject}

pub fn start_pool_with_notices(
  config: Config,
  notice_subject: Subject(ServerNotice),
) -> Result(Connection, Error(PostgresError)) {
  config
  |> notices(notice_subject)
  |> start
}
