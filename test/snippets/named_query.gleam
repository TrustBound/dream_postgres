import dream_errors.{type Error}
import dream_postgres/codecs.{int, text}
import dream_postgres/error.{type PostgresError}
import dream_postgres/pool.{type Connection}
import dream_postgres/query.{named, one, parameter, query}
import dream_postgres/row.{single}

/// The span of this query is named `user.find_by_email`.
pub fn find_user_id(
  connection: Connection,
  email: String,
) -> Result(Int, Error(PostgresError)) {
  query("SELECT id FROM users WHERE email = $1")
  |> named("user.find_by_email")
  |> parameter(text, email)
  |> one(single(int), connection)
}
