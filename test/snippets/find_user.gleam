import dream_errors.{type Error}
import dream_postgres/codecs.{text}
import dream_postgres/error.{type PostgresError}
import dream_postgres/pool.{type Connection}
import dream_postgres/query.{maybe_one, named, parameter, query}
import gleam/option.{type Option}
import snippets/user_row.{type User, user_row}

/// Finds the user with an email, if there is one.
pub fn find_user(
  connection: Connection,
  email: String,
) -> Result(Option(User), Error(PostgresError)) {
  "SELECT id, email, name FROM users WHERE email = $1"
  |> query
  |> named("user.find")
  |> parameter(text, email)
  |> maybe_one(user_row(), connection)
}
