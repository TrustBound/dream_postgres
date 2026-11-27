import dream_errors.{type Error}
import dream_postgres.{
  type Connection, type PostgresError, one, parameter, query,
}
import dream_postgres/codec.{text}
import snippets/user_row.{type User, user_row}

/// Stores a new user, and gives the user with the id that the database
/// gave it.
pub fn create_user(
  connection: Connection,
  email: String,
  name: String,
) -> Result(User, Error(PostgresError)) {
  "INSERT INTO users (email, name) VALUES ($1, $2) RETURNING id, email, name"
  |> query
  |> parameter(text, email)
  |> parameter(text, name)
  |> one(user_row(), connection)
}
