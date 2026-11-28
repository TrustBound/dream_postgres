import dream_errors.{type Error}
import dream_postgres/error.{type PostgresError, constraint_name, sql_state}
import dream_postgres/sql_state.{UniqueViolation}
import gleam/option.{Some}

/// True when the failure is a clash on the unique email of the users
/// table.
pub fn is_email_taken(failure: Error(PostgresError)) -> Bool {
  sql_state(failure) == Some(UniqueViolation)
  && constraint_name(failure) == Some("users_email_key")
}
