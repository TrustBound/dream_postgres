import dream_errors.{Conflict, Timeout, Unavailable}
import dream_postgres/client.{type QueryError, to_error}

pub fn status(error: QueryError) -> Int {
  case to_error(error) {
    Conflict(..) -> 409
    Unavailable(..) -> 503
    Timeout(..) -> 504
    _ -> 500
  }
}
