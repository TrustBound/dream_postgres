import dream_errors.{type Error}
import dream_postgres/codec.{int}
import dream_postgres/error.{type PostgresError}
import dream_postgres/pool.{type Connection}
import dream_postgres/query.{one, query}
import dream_postgres/row.{single}

/// Gives the number of users. The result has one column, so `single`
/// reads it.
pub fn count_users(
  connection: Connection,
) -> Result(Int, Error(PostgresError)) {
  "SELECT count(*) FROM users"
  |> query
  |> one(single(int), connection)
}
