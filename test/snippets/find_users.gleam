import dream_errors.{type Error}
import dream_postgres.{
  type Connection, type PostgresError, all, parameter, query,
}
import dream_postgres/codec.{array, int}
import snippets/user_row.{type User, user_row}

/// Gives the users with the ids. The list goes to PostgreSQL as one array
/// parameter.
pub fn find_users(
  connection: Connection,
  user_ids: List(Int),
) -> Result(List(User), Error(PostgresError)) {
  "SELECT id, email, name FROM users WHERE id = ANY($1) ORDER BY id"
  |> query
  |> parameter(array(int), user_ids)
  |> all(user_row(), connection)
}
