//// A caller's side of a request: the connection handle, and the call that sends
//// a request and waits for its answer.

import dream_postgres/driver/cell.{type Cell, type Format}
import dream_postgres/driver/connection/outcome.{type Outcome}
import dream_postgres/driver/connection/process_message.{
  type DescriptionSource, type Message, type Prepared, type Request,
  type Snapshot, PrepareStatement, Request, RunDetails, RunStatement,
  SnapshotRequest, StatementRequest,
}
import dream_postgres/driver/connection/reply.{
  type CallFailure, type ReplyTo, CallDeadlinePassed, CallProcessDown,
  call_process,
}
import dream_postgres/driver/connection/request_failure.{
  type ConnectionStateError, type PrepareError, type RequestFailure,
  type RunError, ConnectionProcessDown, DeadlinePassed, NoAnswerInTime,
  ProcessGone,
}
import dream_postgres/driver/trace.{type SpanTarget}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/option.{None}
import gleam/result.{map_error}

/// A connection process.
pub type Connection {
  Connection(
    subject: Subject(Message),
    pid: Pid,
    /// How much longer than its deadline a caller waits for the answer:
    /// the time of a cancel, and of a reconnect that runs before the
    /// request.
    reply_margin_milliseconds: Int,
    /// The database and the server that each span of a statement names.
    span_target: SpanTarget,
  )
}

pub fn call(
  connection: Connection,
  make: fn(ReplyTo(reply)) -> Message,
  timeout: Int,
) -> Result(reply, RequestFailure) {
  call_process(connection.pid, send_request(connection, make, _), timeout)
  |> map_error(call_failure)
}

pub fn call_failure(failure: CallFailure) -> RequestFailure {
  case failure {
    CallProcessDown -> ConnectionProcessDown
    CallDeadlinePassed -> DeadlinePassed(cancelled: False)
  }
}

pub fn send_request(
  connection: Connection,
  make: fn(ReplyTo(reply)) -> Message,
  reply_to: ReplyTo(reply),
) -> Nil {
  process.send(connection.subject, make(reply_to))
}

/// Sends a request and waits for its answer. A call that fails gives its
/// failure to `failed`, which makes the request's own error of it.
pub fn request(
  connection: Connection,
  make: fn(ReplyTo(Result(value, error))) -> Request,
  deadline_milliseconds: Int,
  failed: fn(RequestFailure) -> error,
) -> Result(value, error) {
  let wait = deadline_milliseconds + connection.reply_margin_milliseconds
  call(connection, request_message(make, deadline_milliseconds, _), wait)
  |> map_error(failed)
  |> result.flatten
}

pub fn request_message(
  make: fn(ReplyTo(reply)) -> Request,
  deadline_milliseconds: Int,
  reply_to: ReplyTo(reply),
) -> Message {
  Request(make(reply_to), deadline_milliseconds)
}

fn state_error(failure: CallFailure) -> ConnectionStateError {
  case failure {
    CallProcessDown -> ProcessGone
    CallDeadlinePassed -> NoAnswerInTime
  }
}

/// Reads the state of the process. Only the process can fail it: it is
/// gone, or it did not answer in time. The process answers at once, unless
/// it connects again, which takes up to the setup timeout: the caller waits
/// the reply margin, which is longer.
pub fn snapshot(
  connection: Connection,
) -> Result(Snapshot, ConnectionStateError) {
  call_process(
    connection.pid,
    send_request(connection, SnapshotRequest, _),
    connection.reply_margin_milliseconds,
  )
  |> map_error(state_error)
}

pub fn prepare_request(
  sql: String,
  source: DescriptionSource,
  reply_to: ReplyTo(Result(Prepared, PrepareError)),
) -> Request {
  StatementRequest(PrepareStatement(sql, source, reply_to))
}

pub fn run_request(
  sql: String,
  parameters: List(Cell),
  result_formats: List(Format),
  reply_to: ReplyTo(Result(Outcome, RunError)),
) -> Request {
  StatementRequest(
    RunStatement(RunDetails(sql, parameters, result_formats, reply_to, None)),
  )
}
