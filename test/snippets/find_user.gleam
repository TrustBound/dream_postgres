import dream_errors.{type Error}
import dream_postgres.{
  type Connection, type PostgresError, maybe_one, named, parameter, query,
}
import dream_postgres/codec.{text}
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
