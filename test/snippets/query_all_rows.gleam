import dream_pog as pog
import dream_postgres/query
import gleam/string

pub fn find_names(
  result: Result(pog.Returned(String), pog.QueryError),
) -> Result(List(String), String) {
  case query.all_rows(result) {
    Ok(names) -> Ok(names)
    Error(error) -> Error("Database error: " <> string.inspect(error))
  }
}
