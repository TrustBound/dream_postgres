import dream_errors.{type Error}
import dream_postgres/codec.{int, text}
import dream_postgres/error.{type PostgresError}
import dream_postgres/pool.{type Connection}
import dream_postgres/query.{affected, parameter, query}

/// Gives the user a new name, and gives the number of rows that changed:
/// 0 when no user has the id.
pub fn rename_user(
  connection: Connection,
  user_id: Int,
  name: String,
) -> Result(Int, Error(PostgresError)) {
  "UPDATE users SET name = $1 WHERE id = $2"
  |> query
  |> parameter(text, name)
  |> parameter(int, user_id)
  |> affected(connection)
}
