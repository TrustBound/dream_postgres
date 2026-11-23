//// Getting started guide: Step 1
////
//// Starts a connection pool from a DATABASE_URL and turns each error into a
//// message.

import dream_postgres/client as postgres
import gleam/string

pub fn connect(database_url: String) -> Result(postgres.Connection, String) {
  case postgres.from_url(database_url) {
    Ok(connection) -> Ok(connection)
    Error(postgres.InvalidUrl(error)) ->
      Error("DATABASE_URL is not valid: " <> string.inspect(error))
    Error(postgres.PoolStartExited) -> Error("The database pool did not start")
  }
}
