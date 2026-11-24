import dream_pog as pog
import dream_postgres/query

pub fn find_name(
  result: Result(pog.Returned(String), pog.QueryError),
) -> Result(String, String) {
  case query.first_row(result) {
    Ok(name) -> Ok(name)
    Error(query.NotFound) -> Error("User not found")
    Error(query.DatabaseError) -> Error("Database error")
  }
}
