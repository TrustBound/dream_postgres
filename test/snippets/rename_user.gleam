import dream_errors.{type Error}
import dream_postgres.{
  type Connection, type PostgresError, affected, parameter, query,
}
import dream_postgres/codec.{int, text}

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
