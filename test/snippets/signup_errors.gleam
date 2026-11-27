import dream_errors.{type Error}
import dream_postgres.{type PostgresError}
import dream_postgres/error.{column_name, sql_state}
import dream_postgres/sql_state.{NotNullViolation}
import gleam/option.{Some}

pub type SignupError {
  /// The form has no value for this column.
  MissingField(column: String)
  /// Any other failure of the database.
  DatabaseFailed(error: Error(PostgresError))
}

pub fn signup_error(error: Error(PostgresError)) -> SignupError {
  case sql_state(error), column_name(error) {
    Some(NotNullViolation), Some(column) -> MissingField(column)
    _, _ -> DatabaseFailed(error)
  }
}
