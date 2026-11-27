//// Errors that the server reports, for the tests of the mapping to Dream
//// errors and of the accessors.

import dream_postgres/error.{type ServerError, ErrorSeverity, ServerError}
import dream_postgres/sql_state.{type SqlState}
import gleam/option.{type Option, None, Some}

/// An `ERROR` with the message `the message` and the SQLSTATE `sql_state`
/// on the column `public.users.email`, with the constraint name
/// `constraint`, if the server gives one.
///
/// ## Example
///
/// ```gleam
/// server_error.with_sql_state(UniqueViolation, Some("users_email_key"))
/// ```
pub fn with_sql_state(
  sql_state: SqlState,
  constraint: Option(String),
) -> ServerError {
  ServerError(
    severity: ErrorSeverity,
    sql_state:,
    message: "the message",
    detail: None,
    hint: None,
    position: None,
    internal_position: None,
    internal_query: None,
    context: None,
    schema: Some("public"),
    table: Some("users"),
    column: Some("email"),
    data_type: None,
    constraint:,
    file: None,
    line: None,
    routine: None,
    localized_severity: "ERROR",
    other_fields: [],
  )
}
