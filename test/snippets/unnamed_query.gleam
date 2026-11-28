import dream_errors.{type Error}
import dream_postgres/codecs.{int}
import dream_postgres/error.{type PostgresError}
import dream_postgres/pool.{type Connection}
import dream_postgres/query.{one, query}
import dream_postgres/row.{single}

/// This query has no name, so its span is named after the operation and
/// the database, for example `SELECT app`.
pub fn count_users(
  connection: Connection,
) -> Result(Int, Error(PostgresError)) {
  query("SELECT count(*) FROM users")
  |> one(single(int), connection)
}
