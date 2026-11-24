import dream_postgres/query
import dream_postgres_client

pub fn find_name(
  result: Result(
    dream_postgres_client.Returned(String),
    dream_postgres_client.QueryError,
  ),
) -> Result(String, String) {
  case query.first_row(result) {
    Ok(name) -> Ok(name)
    Error(query.NotFound) -> Error("User not found")
    Error(query.DatabaseError) -> Error("Database error")
  }
}
