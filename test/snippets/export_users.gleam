import dream_errors.{type Error}
import dream_postgres/copy.{copy_to}
import dream_postgres/error.{type PostgresError}
import dream_postgres/pool.{type Connection}
import dream_postgres/query.{query}
import gleam/list
import gleam/result
import snippets/copy_users.{type User, user_row}

pub fn export_users(
  connection: Connection,
) -> Result(List(User), Error(PostgresError)) {
  copy_to(
    connection,
    query("SELECT id, email FROM users ORDER BY id"),
    read: user_row(),
    from: [],
    with: list.prepend,
  )
  |> result.map(list.reverse)
}
