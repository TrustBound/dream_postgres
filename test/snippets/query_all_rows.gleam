import dream_postgres/query
import dream_postgres_client
import gleam/string

pub fn find_names(
  result: Result(
    dream_postgres_client.Returned(String),
    dream_postgres_client.QueryError,
  ),
) -> Result(List(String), String) {
  case query.all_rows(result) {
    Ok(names) -> Ok(names)
    Error(error) -> Error("Database error: " <> string.inspect(error))
  }
}
