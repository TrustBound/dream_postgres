import dream_errors.{type Error}
import dream_postgres/query.{first_row, to_error}
import dream_postgres_client.{type QueryError, type Returned}
import gleam/result

pub fn find_name(
  result: Result(Returned(String), QueryError),
) -> Result(String, Error(Nil)) {
  first_row(result)
  |> result.map_error(to_error)
}
