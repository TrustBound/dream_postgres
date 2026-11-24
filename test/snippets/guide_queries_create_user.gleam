//// Queries guide: a constraint violation
////
//// Tells a duplicate email apart from other errors before the result goes
//// to `query.first_row`.

import dream_pog as pog
import dream_postgres/query
import gleam/int
import snippets/guide_queries_show_user.{type Response, Response}
import snippets/guide_queries_sql as sql

pub fn create_user(
  db: pog.Connection,
  name: String,
  email: String,
) -> Response {
  sql.create_user(db, name, email)
  |> created_response
}

pub fn created_response(
  result: Result(pog.Returned(sql.CreateUserRow), pog.QueryError),
) -> Response {
  case result {
    Error(pog.ConstraintViolated(constraint: "users_email_key", ..)) ->
      Response(409, "That email is already taken")
    _ -> new_user_response(result)
  }
}

fn new_user_response(
  result: Result(pog.Returned(sql.CreateUserRow), pog.QueryError),
) -> Response {
  case query.first_row(result) {
    Ok(created) -> Response(201, "Created user " <> int.to_string(created.id))
    Error(_error) -> Response(500, "Internal server error")
  }
}
