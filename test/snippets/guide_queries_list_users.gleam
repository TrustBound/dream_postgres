//// Queries guide: many rows
////
//// Turns the result of `list_users` into a response with `query.all_rows`.

import dream_pog as pog
import dream_postgres/query
import gleam/list
import gleam/string
import snippets/guide_queries_show_user.{type Response, Response}
import snippets/guide_queries_sql as sql

pub fn index_users(db: pog.Connection) -> Response {
  sql.list_users(db)
  |> users_response
}

pub fn users_response(
  result: Result(pog.Returned(sql.ListUsersRow), pog.QueryError),
) -> Response {
  case query.all_rows(result) {
    Ok([]) -> Response(200, "No users yet")
    Ok(users) ->
      Response(200, string.join(list.map(users, fn(user) { user.name }), ", "))
    // all_rows never gives NotFound, so one branch covers the failure
    Error(_error) -> Response(500, "Internal server error")
  }
}
