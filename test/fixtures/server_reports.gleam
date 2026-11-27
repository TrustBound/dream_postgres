//// Server reports (ErrorResponse fields) of the kind that a server sends,
//// for the tests that need one with no server.

import dream_postgres/internal/cell.{type ServerReport, ServerReport}
import gleam/option.{None, Some}

/// The FATAL report of a server that an administrator shuts down
/// (SQLSTATE 57P01).
///
/// ## Example
///
/// ```gleam
/// connection.ServerEndedConnection(server_reports.administrator_shutdown())
/// ```
pub fn administrator_shutdown() -> ServerReport {
  report(
    severity: "FATAL",
    code: "57P01",
    message: "terminating connection due to administrator command",
  )
}

/// The ERROR report of a division by zero (SQLSTATE 22012).
///
/// ## Example
///
/// ```gleam
/// dream_postgres.commit_answer(["ROLLBACK"], Some(server_reports.division_by_zero()))
/// ```
pub fn division_by_zero() -> ServerReport {
  report(severity: "ERROR", code: "22012", message: "division by zero")
}

fn report(
  severity severity: String,
  code code: String,
  message message: String,
) -> ServerReport {
  ServerReport(
    severity:,
    localized_severity: severity,
    code:,
    message:,
    detail: None,
    hint: None,
    position: None,
    internal_position: None,
    internal_query: None,
    context: None,
    schema: None,
    table: None,
    column: None,
    data_type: None,
    constraint: None,
    file: None,
    line: None,
    routine: None,
    other_fields: [],
  )
}

/// A report of a unique violation (23505) with every field set, the
/// German localized severity `FEHLER`, a field that a newer server sends
/// (90), and the severity `severity`.
///
/// ## Example
///
/// ```gleam
/// error.server_error_from_report(server_reports.unique_violation("ERROR"))
/// ```
pub fn unique_violation(severity: String) -> ServerReport {
  ServerReport(
    severity:,
    localized_severity: "FEHLER",
    code: "23505",
    message: "duplicate key value violates unique constraint",
    detail: Some("Key (email)=(a@b) already exists."),
    hint: Some("a hint"),
    position: Some(8),
    internal_position: Some(3),
    internal_query: Some("select 1"),
    context: Some("SQL function"),
    schema: Some("public"),
    table: Some("users"),
    column: Some("email"),
    data_type: Some("text"),
    constraint: Some("users_email_key"),
    file: Some("nbtinsert.c"),
    line: Some(666),
    routine: Some("_bt_check_unique"),
    other_fields: [#(90, "a field of a newer server")],
  )
}
