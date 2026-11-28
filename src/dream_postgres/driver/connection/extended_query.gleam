//// The caller's side of the Extended Query protocol: Parse and Describe, then
//// Bind and Execute.

import dream_postgres/driver/cell.{
  type Cell, type Format, type StatementDescription,
}
import dream_postgres/driver/connection/call.{
  type Connection, prepare_request, request, run_request,
}
import dream_postgres/driver/connection/outcome.{type Outcome}
import dream_postgres/driver/connection/process_message.{
  CachedDescription, HousekeepingRunRequest, ServerDescription,
}
import dream_postgres/driver/connection/request_failure.{
  type HousekeepingError, type PrepareError, type RunError, HousekeepingFailed,
  PrepareFailed, RunFailed,
}
import dream_postgres/driver/connection/statement.{type Statement, recorded_text}
import dream_postgres/driver/connection/tracing.{
  outcome_ending, prepare_ending, traced,
}
import dream_postgres/driver/housekeeping_sql.{type HousekeepingSql}
import gleam/result

/// Prepares a statement and describes it, before any run. A statement
/// that the cache holds is answered from the cache, with no round trip.
/// That description can be stale: after a schema change that changes the
/// statement's result columns, such as `ALTER TABLE ... ALTER COLUMN
/// TYPE` or `DROP COLUMN`, it still shows the old columns, and a run of
/// the statement gives `RunStatementChanged` with the new description.
/// `describe_current` always asks the server.
///
/// ## Parameters
///
/// - `connection`: the connection
/// - `sql`: the statement
/// - `deadline_milliseconds`: the longest time to wait for the answer
///
/// ## Returns
///
/// - `Ok(StatementDescription)`: the parameter types and the result columns
/// - `Error(PrepareRefused(report, status))`: the server refused it
/// - `Error(PrepareUnencodable(error))`: the SQL cannot be written
/// - `Error(PrepareNotConnected(error))`: a supervised process has not
///   connected yet
/// - `Error(PrepareFailed(failure))`: the request failed on its connection
pub fn prepare(
  connection: Connection,
  statement: Statement,
  deadline_milliseconds: Int,
) -> Result(StatementDescription, PrepareError) {
  {
    use <-
      traced(connection, statement, recorded_text(statement), _, prepare_ending)
    request(
      connection,
      prepare_request(statement.sql, CachedDescription, _),
      deadline_milliseconds,
      PrepareFailed,
    )
  }
  |> result.map(fn(prepared) { prepared.description })
}

/// Prepares a statement and gives the server's description of it now. A
/// statement that the cache holds is closed and prepared again under a
/// new name, in one round trip, and the cache keeps the new description
/// for the next run. A Describe of the cached statement cannot give it:
/// after a change of the result columns the server refuses that Describe
/// with 0A000, "cached plan must not change result type" (checked on
/// PostgreSQL 16 and 19).
///
/// ## Parameters
///
/// - `connection`: the connection
/// - `sql`: the statement
/// - `deadline_milliseconds`: the longest time to wait for the answer
///
/// ## Returns
///
/// - `Ok(StatementDescription)`: the parameter types and the result
///   columns, as the server describes them now
/// - `Error(PrepareRefused(report, status))`: the server refused it
/// - `Error(PrepareUnencodable(error))`: the SQL cannot be written
/// - `Error(PrepareNotConnected(error))`: a supervised process has not
///   connected yet
/// - `Error(PrepareFailed(failure))`: the request failed on its connection
pub fn describe_current(
  connection: Connection,
  statement: Statement,
  deadline_milliseconds: Int,
) -> Result(StatementDescription, PrepareError) {
  {
    use <-
      traced(connection, statement, recorded_text(statement), _, prepare_ending)
    request(
      connection,
      prepare_request(statement.sql, ServerDescription, _),
      deadline_milliseconds,
      PrepareFailed,
    )
  }
  |> result.map(fn(prepared) { prepared.description })
}

/// Runs a statement with its parameters. Each cell carries its own format.
///
/// ## Parameters
///
/// - `connection`: the connection
/// - `sql`: the statement
/// - `parameters`: one cell for each parameter
/// - `result_formats`: the format of the result columns: none for text,
///   one for all, or one for each column
/// - `deadline_milliseconds`: the longest time to wait for the result
///
/// ## Returns
///
/// - `Ok(Outcome)`: the columns, the rows of cells, the tag and the count
/// - `Error(RunRefused(report, status))`: the server refused it
/// - `Error(RunCopyRefused)`: the statement is a COPY
/// - `Error(RunStatementChanged(description))`: the statement changed on
///   the server since the driver cached it, and did not run
/// - `Error(RunUnencodable(error))`: the SQL or a parameter cannot be
///   written
/// - `Error(RunNotConnected(error))`: a supervised process has not
///   connected yet
/// - `Error(RunFailed(failure))`: the request failed on its connection
pub fn run(
  connection: Connection,
  statement: Statement,
  parameters: List(Cell),
  result_formats: List(Format),
  deadline_milliseconds: Int,
) -> Result(Outcome, RunError) {
  use <-
    traced(connection, statement, recorded_text(statement), _, outcome_ending)
  run_without_span(
    connection,
    statement.sql,
    parameters,
    result_formats,
    deadline_milliseconds,
  )
}

/// Runs a statement that the driver sends for its own housekeeping, from
/// its own processes, with no span: the catalog load. A span records a
/// call that the app made; a statement of the driver's own has no caller
/// span to nest under. It runs on the unnamed statement in one round
/// trip, with no parameter and text results, and never enters the
/// statement cache.
///
/// ## Parameters
///
/// - `connection`: the connection
/// - `sql`: the housekeeping statement
/// - `deadline_milliseconds`: the longest time to wait for the result
///
/// ## Returns
///
/// - `Ok(Outcome)`: the columns, the rows of cells, the tag and the count
/// - `Error(HousekeepingRefused(report, status))`: the server refused it
/// - `Error(HousekeepingAnswerUnexpected)`: the server answered with a
///   COPY
/// - `Error(HousekeepingNotConnected(error))`: a supervised process has
///   not connected yet
/// - `Error(HousekeepingFailed(failure))`: the request failed on its
///   connection
pub fn run_housekeeping(
  connection: Connection,
  sql: HousekeepingSql,
  deadline_milliseconds: Int,
) -> Result(Outcome, HousekeepingError) {
  request(
    connection,
    HousekeepingRunRequest(sql, _),
    deadline_milliseconds,
    HousekeepingFailed,
  )
}

fn run_without_span(
  connection: Connection,
  sql: String,
  parameters: List(Cell),
  result_formats: List(Format),
  deadline_milliseconds: Int,
) -> Result(Outcome, RunError) {
  request(
    connection,
    run_request(sql, parameters, result_formats, _),
    deadline_milliseconds,
    RunFailed,
  )
}
