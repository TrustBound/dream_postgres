import dream_errors.{type Error}
import dream_postgres/config.{type Config, type ServerNotice, notices}
import dream_postgres/error.{type PostgresError}
import dream_postgres/pool.{type Connection, start}
import gleam/erlang/process.{type Subject}
import gleam/pair
import gleam/result

/// Starts a pool that sends each notice of the server to a new subject of
/// the calling process.
pub fn start_with_notices(
  config: Config,
) -> Result(#(Connection, Subject(ServerNotice)), Error(PostgresError)) {
  let notice_subject = process.new_subject()
  config
  |> notices(notice_subject)
  |> start
  |> result.map(pair.new(_, notice_subject))
}

/// The text of a notice for a log line, such as
/// `NOTICE: the table is empty`.
pub fn notice_line(notice: ServerNotice) -> String {
  notice.localized_severity <> ": " <> notice.message
}
