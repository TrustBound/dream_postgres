import dream_errors.{type Error}
import dream_postgres/codecs.{int}
import dream_postgres/codecs/array.{array}
import dream_postgres/error.{type PostgresError}
import dream_postgres/pool.{type Connection}
import dream_postgres/query.{all, parameter, query}
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
