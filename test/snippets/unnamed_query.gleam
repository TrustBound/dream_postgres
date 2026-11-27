import dream_errors.{type Error}
import dream_postgres.{type Connection, type PostgresError, one, query, single}
import dream_postgres/codec.{int}

/// This query has no name, so its span is named after the operation and
/// the database, for example `SELECT app`.
pub fn count_users(
  connection: Connection,
) -> Result(Int, Error(PostgresError)) {
  query("SELECT count(*) FROM users")
  |> one(single(int), connection)
}
