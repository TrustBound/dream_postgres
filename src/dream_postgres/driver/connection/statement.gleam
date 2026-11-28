//// A statement, and the names that a caller gives it for its span.

import gleam/option.{type Option, None, Some}

/// The text of a statement, and the caller's name of it for its span.
pub type Statement {
  Statement(
    sql: String,
    name: Option(String),
    /// The text that the span records as `db.query.text` in place of the
    /// SQL. It never goes to the server.
    span_text: Option(String),
  )
}

/// A statement with no name: its span is named after its operation and
/// the database, for example `SELECT app`, or after the database alone
/// when the operation is not known, as after a failure.
///
/// ## Parameters
///
/// - `sql`: the text of the statement
///
/// ## Returns
///
/// The statement.
pub fn statement(sql: String) -> Statement {
  Statement(sql:, name: None, span_text: None)
}

/// Names a statement for its span. The name is recorded as
/// `db.query.summary`, and it becomes the span's name (OTel semantic
/// conventions at commit 7c8eb86d04, docs/db/database-spans.md line 56:
/// "The **span name** SHOULD be
/// `{db.query.summary}` if a summary is available."). So it must be
/// low-cardinality and hold no value: one name for one kind of statement,
/// for example `post.create`. The name plays no part in the statement
/// cache, whose key is the text.
///
/// ## Parameters
///
/// - `statement`: the statement
/// - `name`: the app's name of the statement
///
/// ## Returns
///
/// The statement with the name.
pub fn named(statement: Statement, name: String) -> Statement {
  Statement(..statement, name: Some(name))
}

/// Sets the text that the statement's span records as `db.query.text`, in
/// place of the SQL, for example the SQL with its secrets or literals
/// replaced. The SQL is still what the server runs, and the key of the
/// statement cache: the span text never goes to the server.
///
/// A simple query (`run_simple_query`) records no text without it, because its SQL is
/// not parameterized and may hold values (OTel semantic conventions at
/// commit 7c8eb86d04, docs/db/database-spans.md note 15, line 303:
/// "Non-parameterized query text SHOULD NOT be collected by default
/// unless there is sanitization that excludes sensitive data"). With a
/// span text, the simple query records it, as the sanitized form (lines
/// 462-466). The caller makes sure that it holds no secret.
///
/// ## Parameters
///
/// - `statement`: the statement
/// - `text`: the text for the span
///
/// ## Returns
///
/// The statement with the span text.
pub fn span_text(statement: Statement, text text: String) -> Statement {
  Statement(..statement, span_text: Some(text))
}

/// The text that the span of a statement records: its span text when the
/// caller set one, else its SQL.
pub fn recorded_text(statement: Statement) -> Option(String) {
  option.or(statement.span_text, Some(statement.sql))
}
