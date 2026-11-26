import dream_postgres/client.{type QueryError, broken_promise}

pub fn error_message(error: QueryError) -> String {
  case broken_promise(error) {
    Ok(message) -> message
    Error(Nil) -> "The query failed"
  }
}
