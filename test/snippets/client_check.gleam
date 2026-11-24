import dream_postgres/client as postgres
import gleam/string

pub fn describe_database(connection: postgres.Connection) -> String {
  case postgres.check(connection) {
    Ok(Nil) -> "The database answers"
    Error(error) -> "The database did not answer: " <> string.inspect(error)
  }
}
