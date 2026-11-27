import dream_errors.{type Error}
import dream_postgres.{type Connection, type PostgresError, one, query, single}
import dream_postgres/codec.{int}

/// Gives the number of users. The result has one column, so `single`
/// reads it.
pub fn count_users(
  connection: Connection,
) -> Result(Int, Error(PostgresError)) {
  "SELECT count(*) FROM users"
  |> query
  |> one(single(int), connection)
}
