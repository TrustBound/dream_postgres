//// ServerReport values for the driver tests: the fields that every
//// ErrorResponse and NoticeResponse has, and no other field.

import dream_postgres/driver/cell.{type ServerReport, ServerReport}
import gleam/option.{None}

/// A report with a severity, a SQLSTATE code and a message, and no other
/// field.
pub fn server_report(
  severity: String,
  code: String,
  text: String,
) -> ServerReport {
  ServerReport(
    severity:,
    localized_severity: severity,
    code:,
    message: text,
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
