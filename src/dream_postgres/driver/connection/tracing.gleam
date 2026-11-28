//// The span of a request: its target, its ending, and the text of its failures.

import dream_postgres/driver/cell.{type ServerReport}
import dream_postgres/driver/connection/call.{type Connection}
import dream_postgres/driver/connection/copy_exchange.{type CopyDone}
import dream_postgres/driver/connection/event.{
  ConnectionLost, ProtocolViolation, ServerEndedConnection,
}
import dream_postgres/driver/connection/outcome.{type Outcome}
import dream_postgres/driver/connection/process_message.{type Prepared}
import dream_postgres/driver/connection/request_failure.{
  type CopyError, type PrepareError, type RequestFailure, type RunError,
  type SimpleQueryError, AppFailed, ConnectionEnded, ConnectionProcessDown,
  CopyFailed, CopyNotConnected, CopyNotStarted, CopyRefused, CopyUnencodable,
  DeadlinePassed, PrepareFailed, PrepareNotConnected, PrepareRefused,
  PrepareUnencodable, RunCopyRefused, RunFailed, RunNotConnected, RunRefused,
  RunStatementChanged, RunUnencodable, SimpleQueryCopyRefused, SimpleQueryFailed,
  SimpleQueryNotConnected, SimpleQueryRefused, SimpleQueryRequestFailed,
  SimpleQueryUnencodable,
}
import dream_postgres/driver/connection/settings.{type ConnectionConfig}
import dream_postgres/driver/connection/statement.{type Statement}
import dream_postgres/driver/login
import dream_postgres/driver/trace.{
  type SpanEnd, type SpanTarget, Failed, SpanQuery, SpanTarget, Worked,
}
import dream_postgres/driver/transport
import gleam/list
import gleam/option.{type Option, None, Some}

pub fn span_target(config: ConnectionConfig) -> SpanTarget {
  let address = config.transport.address
  SpanTarget(
    database: login.database(config.login),
    host: transport.host(address),
    port: transport.port(address),
  )
}

/// Runs the request of a statement inside its span. The span starts and
/// ends in the caller's process, on every answer. A caller that is killed
/// during the call leaves its span unended: the span is not exported, as
/// for any span of a process that ends before it ends its span.
pub fn traced(
  connection: Connection,
  statement: Statement,
  text: Option(String),
  work: fn() -> Result(value, error),
  ending: fn(Result(value, error)) -> SpanEnd,
) -> Result(value, error) {
  let span =
    trace.start(
      connection.span_target,
      SpanQuery(summary: statement.name, text:),
    )
  let result = work()
  trace.end(span, ending(result))
  result
}

pub fn prepare_ending(result: Result(Prepared, PrepareError)) -> SpanEnd {
  case result {
    Ok(prepared) -> Worked(operation: None, warning_code: prepared.warning_code)
    Error(error) ->
      failed_ending(prepare_error_name(error), prepare_report(error))
  }
}

pub fn outcome_ending(result: Result(Outcome, RunError)) -> SpanEnd {
  case result {
    Ok(outcome) -> worked_ending(outcome)
    Error(error) -> failed_ending(run_error_name(error), run_report(error))
  }
}

fn worked_ending(outcome: Outcome) -> SpanEnd {
  Worked(
    operation: Some(trace.operation_of_tag(outcome.result.tag)),
    warning_code: warning_code([outcome]),
  )
}

/// The last warning code of the notices of the outcomes, in order.
fn warning_code(outcomes: List(Outcome)) -> Option(String) {
  outcomes
  |> list.flat_map(fn(outcome) { outcome.notices })
  |> list.map(fn(notice) { notice.code })
  |> trace.last_warning_code
}

/// A simple query names its operation only when it ran exactly one statement.
pub fn simple_query_ending(
  result: Result(List(Outcome), SimpleQueryError),
) -> SpanEnd {
  case result {
    Ok([outcome]) -> worked_ending(outcome)
    Ok(several_or_none) ->
      Worked(operation: None, warning_code: warning_code(several_or_none))
    Error(error) ->
      failed_ending(simple_query_error_name(error), simple_query_report(error))
  }
}

/// The server confirmed the COPY with its CopyInResponse or
/// CopyOutResponse, and ends it with the tag `COPY`.
pub fn copy_ending(
  result: Result(CopyDone(value), CopyError(reason)),
) -> SpanEnd {
  case result {
    Ok(done) -> Worked(operation: Some("COPY"), warning_code: done.warning_code)
    Error(error) -> failed_ending(copy_error_name(error), copy_report(error))
  }
}

/// `error.type` is the server's SQLSTATE when there is one, else the
/// error's name (OTel semantic conventions at commit 7c8eb86d04,
/// docs/db/database-spans.md note 9: `error.type` "SHOULD match the
/// `db.response.status_code` returned by the database or the client
/// library, or the canonical name of exception that occurred").
fn failed_ending(name: String, report: Option(ServerReport)) -> SpanEnd {
  case report {
    Some(report) ->
      Failed(error_type: report.code, status_code: Some(report.code))
    None -> Failed(error_type: name, status_code: None)
  }
}

/// The name of a request failure: its constructor's name.
/// A failure of an ended connection is named by the case of its end.
fn failure_name(failure: RequestFailure) -> String {
  case failure {
    ConnectionProcessDown -> "ConnectionProcessDown"
    DeadlinePassed(..) -> "DeadlinePassed"
    ConnectionEnded(ConnectionLost(..)) -> "ConnectionLost"
    ConnectionEnded(ServerEndedConnection(..)) -> "ServerEndedConnection"
    ConnectionEnded(ProtocolViolation(..)) -> "ProtocolViolation"
  }
}

fn failure_report(failure: RequestFailure) -> Option(ServerReport) {
  case failure {
    ConnectionEnded(ServerEndedConnection(report:)) -> Some(report)
    ConnectionProcessDown
    | DeadlinePassed(..)
    | ConnectionEnded(ConnectionLost(..))
    | ConnectionEnded(ProtocolViolation(..)) -> None
  }
}

/// The name of a prepare error: its constructor's name, or the name of the
/// request failure that it holds.
fn prepare_error_name(error: PrepareError) -> String {
  case error {
    PrepareFailed(failure) -> failure_name(failure)
    PrepareNotConnected(..) -> "PrepareNotConnected"
    PrepareUnencodable(..) -> "PrepareUnencodable"
    PrepareRefused(..) -> "PrepareRefused"
  }
}

fn prepare_report(error: PrepareError) -> Option(ServerReport) {
  case error {
    PrepareFailed(failure) -> failure_report(failure)
    PrepareRefused(report:, ..) -> Some(report)
    PrepareNotConnected(..) | PrepareUnencodable(..) -> None
  }
}

/// The name of a run error: its constructor's name, or the name of the
/// request failure that it holds.
fn run_error_name(error: RunError) -> String {
  case error {
    RunFailed(failure) -> failure_name(failure)
    RunNotConnected(..) -> "RunNotConnected"
    RunUnencodable(..) -> "RunUnencodable"
    RunRefused(..) -> "RunRefused"
    RunCopyRefused -> "RunCopyRefused"
    RunStatementChanged(..) -> "RunStatementChanged"
  }
}

fn run_report(error: RunError) -> Option(ServerReport) {
  case error {
    RunFailed(failure) -> failure_report(failure)
    RunRefused(report:, ..) -> Some(report)
    RunNotConnected(..)
    | RunUnencodable(..)
    | RunCopyRefused
    | RunStatementChanged(..) -> None
  }
}

/// The name of a simple query error: its constructor's name, or the name of the
/// request failure that it holds.
fn simple_query_error_name(error: SimpleQueryError) -> String {
  case error {
    SimpleQueryRequestFailed(failure) -> failure_name(failure)
    SimpleQueryNotConnected(..) -> "SimpleQueryNotConnected"
    SimpleQueryUnencodable(..) -> "SimpleQueryUnencodable"
    SimpleQueryRefused(..) -> "SimpleQueryRefused"
    SimpleQueryFailed(..) -> "SimpleQueryFailed"
    SimpleQueryCopyRefused(..) -> "SimpleQueryCopyRefused"
  }
}

fn simple_query_report(error: SimpleQueryError) -> Option(ServerReport) {
  case error {
    SimpleQueryRequestFailed(failure) -> failure_report(failure)
    SimpleQueryRefused(report:, ..) | SimpleQueryFailed(report:, ..) ->
      Some(report)
    SimpleQueryNotConnected(..)
    | SimpleQueryUnencodable(..)
    | SimpleQueryCopyRefused(..) -> None
  }
}

/// The name of a COPY error: its constructor's name, or the name of the
/// request failure that it holds.
fn copy_error_name(error: CopyError(reason)) -> String {
  case error {
    AppFailed(..) -> "AppFailed"
    CopyFailed(failure) -> failure_name(failure)
    CopyNotConnected(..) -> "CopyNotConnected"
    CopyUnencodable(..) -> "CopyUnencodable"
    CopyRefused(..) -> "CopyRefused"
    CopyNotStarted(..) -> "CopyNotStarted"
  }
}

fn copy_report(error: CopyError(reason)) -> Option(ServerReport) {
  case error {
    CopyFailed(failure) -> failure_report(failure)
    CopyRefused(report:, ..) -> Some(report)
    AppFailed(..)
    | CopyNotConnected(..)
    | CopyUnencodable(..)
    | CopyNotStarted(..) -> None
  }
}
