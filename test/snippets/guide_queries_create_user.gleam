//// Queries guide: a constraint violation
////
//// Tells a duplicate email apart from other errors before the result goes
//// to `query.first_row`.

import dream_postgres/query
import dream_postgres_client
import gleam/int
import snippets/guide_queries_show_user.{type Response, Response}
import snippets/guide_queries_sql as sql

pub fn create_user(
  db: dream_postgres_client.Connection,
  name: String,
  email: String,
) -> Response {
  sql.create_user(db, name, email)
  |> created_response
}

pub fn created_response(
  result: Result(
    dream_postgres_client.Returned(sql.CreateUserRow),
    dream_postgres_client.QueryError,
  ),
) -> Response {
  case result {
    Error(dream_postgres_client.ConstraintViolated(
      constraint: "users_email_key",
      ..,
    )) -> Response(409, "That email is already taken")
    _ -> new_user_response(result)
  }
}

fn new_user_response(
  result: Result(
    dream_postgres_client.Returned(sql.CreateUserRow),
    dream_postgres_client.QueryError,
  ),
) -> Response {
  case query.first_row(result) {
    Ok(created) -> Response(201, "Created user " <> int.to_string(created.id))
    Error(_error) -> Response(500, "Internal server error")
  }
}
