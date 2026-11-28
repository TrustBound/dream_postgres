import dream_errors.{type Error, Conflict}
import dream_postgres/codec.{int, text}
import dream_postgres/error.{type PostgresError}
import dream_postgres/pool.{type Connection}
import dream_postgres/query.{named, one, parameter, query}
import dream_postgres/row.{single}
import gleam/int
import snippets/upgrade_show_user.{type Response, Response}

pub fn create_user(
  connection: Connection,
  name: String,
  email: String,
) -> Result(Int, Error(PostgresError)) {
  "INSERT INTO users (name, email) VALUES ($1, $2) RETURNING id"
  |> query
  |> named("user.create")
  |> parameter(text, name)
  |> parameter(text, email)
  |> one(single(int), connection)
}

pub fn created_response(result: Result(Int, Error(PostgresError))) -> Response {
  case result {
    Ok(id) -> Response(201, "Created user " <> int.to_string(id))
    Error(Conflict(..)) -> Response(409, "That email is already taken")
    Error(_other) -> Response(500, "Internal server error")
  }
}
