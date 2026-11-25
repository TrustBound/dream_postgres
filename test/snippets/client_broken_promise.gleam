import dream_postgres/client as postgres

pub fn error_message(error: postgres.QueryError) -> String {
  case postgres.broken_promise(error) {
    Ok(message) -> message
    Error(Nil) -> "The query failed"
  }
}
