import dream_errors
import dream_postgres/client as postgres

pub fn status(error: postgres.QueryError) -> Int {
  case postgres.to_error(error) {
    dream_errors.Conflict(..) -> 409
    dream_errors.Unavailable(..) -> 503
    dream_errors.Timeout(..) -> 504
    _ -> 500
  }
}
