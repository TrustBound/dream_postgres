//// The caller's side of the Simple Query protocol.

import dream_postgres/driver/connection/call.{type Connection, request}
import dream_postgres/driver/connection/outcome.{type Outcome}
import dream_postgres/driver/connection/process_message.{
  HousekeepingSimpleQueryRequest, SimpleQueryRequest,
}
import dream_postgres/driver/connection/request_failure.{
  type HousekeepingError, type SimpleQueryError, HousekeepingFailed,
  SimpleQueryRequestFailed,
}
import dream_postgres/driver/connection/statement.{type Statement}
import dream_postgres/driver/connection/tracing.{simple_query_ending, traced}
import dream_postgres/driver/housekeeping_sql.{type HousekeepingSql}

/// Runs a simple query: one or more SQL statements in one Query message, for example
/// `BEGIN`, `COMMIT` or several statements at once. Cells come in text.
///
/// ## Parameters
///
/// - `connection`: the connection
/// - `sql`: the simple query
/// - `deadline_milliseconds`: the longest time to wait for all results
///
/// ## Returns
///
/// - `Ok(outcomes)`: one outcome for each statement, in order
/// - `Error(SimpleQueryRefused(report, status))`: the server refused the first
///   statement, so none ran
/// - `Error(SimpleQueryFailed(completed, report, status))`: a later statement
///   failed, after the ones in `completed` ran
/// - `Error(SimpleQueryCopyRefused(completed))`: a statement is a COPY
/// - `Error(SimpleQueryUnencodable(error))`: the simple query cannot be written
/// - `Error(SimpleQueryNotConnected(error))`: a supervised process has not
///   connected yet
/// - `Error(SimpleQueryRequestFailed(failure))`: the request failed on its
///   connection
pub fn run_simple_query(
  connection: Connection,
  statement: Statement,
  deadline_milliseconds: Int,
) -> Result(List(Outcome), SimpleQueryError) {
  // A simple query is not parameterized, so its SQL may hold values: it is not
  // recorded (OTel semantic conventions at commit 7c8eb86d04,
  // docs/db/database-spans.md note 15: "Non-parameterized query text SHOULD NOT
  // be collected by default unless there is sanitization"). A span text is
  // the caller's sanitized form, so the span records it (see `span_text`).
  use <-
    traced(connection, statement, statement.span_text, _, simple_query_ending)
  run_simple_query_without_span(
    connection,
    statement.sql,
    deadline_milliseconds,
  )
}

/// Runs a statement that the driver sends for its own housekeeping, from
/// its own processes, with the simple query protocol and no span: a pool
/// member's ROLLBACK and health check.
///
/// ## Parameters
///
/// - `connection`: the connection
/// - `sql`: the housekeeping statement
/// - `deadline_milliseconds`: the longest time to wait for the result
///
/// ## Returns
///
/// - `Ok(outcomes)`: the one outcome of the statement
/// - `Error(HousekeepingRefused(report, status))`: the server refused it
/// - `Error(HousekeepingAnswerUnexpected)`: the server answered with a
///   COPY, or with an error after a result
/// - `Error(HousekeepingNotConnected(error))`: a supervised process has
///   not connected yet
/// - `Error(HousekeepingFailed(failure))`: the request failed on its
///   connection
pub fn run_housekeeping_simple_query(
  connection: Connection,
  sql: HousekeepingSql,
  deadline_milliseconds: Int,
) -> Result(List(Outcome), HousekeepingError) {
  request(
    connection,
    HousekeepingSimpleQueryRequest(sql, _),
    deadline_milliseconds,
    HousekeepingFailed,
  )
}

/// Runs a listener's LISTEN or UNLISTEN, from the listener's own process,
/// with no span. The statement holds the caller's channel, so it is not a
/// housekeeping statement of the closed set, and its encoding stays
/// checked.
///
/// ## Parameters
///
/// - `connection`: the connection
/// - `sql`: the LISTEN or UNLISTEN
/// - `deadline_milliseconds`: the longest time to wait for all results
///
/// ## Returns
///
/// The result of `run_simple_query`, with the same errors.
pub fn run_listener_simple_query(
  connection: Connection,
  sql: String,
  deadline_milliseconds: Int,
) -> Result(List(Outcome), SimpleQueryError) {
  run_simple_query_without_span(connection, sql, deadline_milliseconds)
}

fn run_simple_query_without_span(
  connection: Connection,
  sql: String,
  deadline_milliseconds: Int,
) -> Result(List(Outcome), SimpleQueryError) {
  request(
    connection,
    SimpleQueryRequest(sql, _),
    deadline_milliseconds,
    SimpleQueryRequestFailed,
  )
}
