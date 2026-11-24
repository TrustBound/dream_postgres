//// Queries guide: keep the cause of a failure
////
//// Writes the Pog error to standard error before `query.first_row` turns
//// it into `DatabaseError`.

import dream_postgres_client
import gleam/io
import gleam/string
import snippets/guide_queries_show_user.{type Response, user_response}
import snippets/guide_queries_sql as sql

pub fn show_user(db: dream_postgres_client.Connection, id: Int) -> Response {
  sql.find_user(db, id)
  |> log_failure
  |> user_response
}

pub fn log_failure(
  result: Result(
    dream_postgres_client.Returned(row),
    dream_postgres_client.QueryError,
  ),
) -> Result(
  dream_postgres_client.Returned(row),
  dream_postgres_client.QueryError,
) {
  case result {
    Error(error) -> io.println_error("Query failed: " <> string.inspect(error))
    Ok(_returned) -> Nil
  }
  result
}
