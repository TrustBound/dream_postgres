//// Queries guide: one row
////
//// Turns the result of `find_user` into a response with `query.first_row`.

import dream_pog as pog
import dream_postgres/query
import gleam/int
import snippets/guide_queries_sql as sql

pub type Response {
  Response(status: Int, body: String)
}

pub fn show_user(db: pog.Connection, id: Int) -> Response {
  sql.find_user(db, id)
  |> user_response
}

pub fn user_response(
  result: Result(pog.Returned(sql.FindUserRow), pog.QueryError),
) -> Response {
  case query.first_row(result) {
    Ok(user) ->
      Response(
        200,
        int.to_string(user.id) <> ": " <> user.name <> " <" <> user.email <> ">",
      )
    Error(query.NotFound) -> Response(404, "No user with that id")
    Error(query.DatabaseError) -> Response(500, "Internal server error")
  }
}
