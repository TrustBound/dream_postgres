import dream_errors.{type Error, Conflict}
import dream_postgres.{
  type Connection, type PostgresError, named, one, parameter, query, single,
}
import dream_postgres/codec.{int, text}
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
