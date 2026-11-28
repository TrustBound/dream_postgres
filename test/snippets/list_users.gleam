import dream_errors.{type Error}
import dream_postgres/error.{type PostgresError}
import dream_postgres/pool.{type Connection}
import dream_postgres/query.{all, query}
import snippets/user_row.{type User, user_row}

/// Gives every user, in the order of their ids.
pub fn list_users(
  connection: Connection,
) -> Result(List(User), Error(PostgresError)) {
  "SELECT id, email, name FROM users ORDER BY id"
  |> query
  |> all(user_row(), connection)
}
