import dream_postgres/client.{type QueryError, infinite_value}

pub fn error_message(error: QueryError) -> String {
  case infinite_value(error) {
    Ok(message) -> message
    Error(Nil) -> "The query failed"
  }
}
