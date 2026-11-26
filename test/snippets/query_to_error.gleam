import dream_errors
import dream_postgres/query
import dream_postgres_client
import gleam/result

pub fn find_name(
  result: Result(
    dream_postgres_client.Returned(String),
    dream_postgres_client.QueryError,
  ),
) -> Result(String, dream_errors.Error(Nil)) {
  query.first_row(result)
  |> result.map_error(query.to_error)
}
