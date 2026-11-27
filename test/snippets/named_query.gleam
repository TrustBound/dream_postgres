import dream_errors.{type Error}
import dream_postgres.{
  type Connection, type PostgresError, named, one, parameter, query, single,
}
import dream_postgres/codec.{int, text}

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
