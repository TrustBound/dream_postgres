import dream_errors.{type Error}
import dream_postgres.{type Connection, type PostgresError, all, query}
import snippets/user_row.{type User, user_row}

/// Gives every user, in the order of their ids.
pub fn list_users(
  connection: Connection,
) -> Result(List(User), Error(PostgresError)) {
  "SELECT id, email, name FROM users ORDER BY id"
  |> query
  |> all(user_row(), connection)
}
