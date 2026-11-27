//// Inputs of the copy step of `dream_postgres/driver/query` for its
//// tests: messages of the server and calls of the app, in the flows of the
//// PostgreSQL documentation ("Message Flow", "COPY Operations"), and what
//// the step gives back for each.

import dream_postgres/driver/message.{
  type BackendMessage, BindComplete, CopyInResponse, CopyOutResponse,
  ParseComplete,
}
import dream_postgres/driver/query.{
  type CopyResult, type CopyState, type Failure, type Outcome, type Phase,
  CopyFrom, Outcome,
}
import dream_postgres/internal/cell.{
  type ServerReport, type TransactionStatus, ServerReport, TextFormat,
}
import gleam/bit_array
import gleam/list
import gleam/option.{None}

/// What happens next: a message of the server, or a call of the app.
pub type Input {
  FromServer(message: BackendMessage)
  AppFinishes
  AppAbandons
  DeadlinePasses
}

/// What the step gave for one input, without its state.
pub type Seen {
  Started
  Row(row: BitArray)
  Sent(bytes: BitArray)
  Waited
  Finished(outcome: Outcome(CopyResult, Failure))
  ConnectionEnded(report: ServerReport)
  Unexpected(phase: Phase)
}

/// A server report with only a severity, a code and a message.
pub fn report(severity: String, code: String, text: String) -> ServerReport {
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

/// The server's error for a row that is not valid.
pub fn invalid_row() -> ServerReport {
  report("ERROR", "22P02", "invalid input syntax for type integer: \"x\"")
}

/// The server's error for a COPY that the client abandoned.
pub fn abandoned_report() -> ServerReport {
  report(
    "ERROR",
    "57014",
    "COPY from stdin failed: the client abandoned the COPY",
  )
}

/// The start of a `COPY ... FROM STDIN`, up to its CopyInResponse.
pub fn copy_in_start() -> List(Input) {
  [
    FromServer(ParseComplete),
    FromServer(BindComplete),
    FromServer(CopyInResponse(TextFormat, [TextFormat])),
  ]
}

/// The start of a `COPY ... TO STDOUT`, up to its CopyOutResponse.
pub fn copy_out_start() -> List(Input) {
  [
    FromServer(ParseComplete),
    FromServer(BindComplete),
    FromServer(CopyOutResponse(TextFormat, [TextFormat])),
  ]
}

/// The start of a `COPY ... FROM STDIN`, followed by `inputs`.
pub fn after_copy_in_start(inputs: List(Input)) -> List(Input) {
  list.append(copy_in_start(), inputs)
}

/// The start of a `COPY ... TO STDOUT`, followed by `inputs`.
pub fn after_copy_out_start(inputs: List(Input)) -> List(Input) {
  list.append(copy_out_start(), inputs)
}

/// The bytes of a Sync.
pub fn sync() -> BitArray {
  <<"S", 4:32>>
}

/// The bytes of a CopyDone and a Sync.
pub fn copy_done_and_sync() -> BitArray {
  <<"c", 4:32, "S", 4:32>>
}

/// The bytes of the CopyFail that abandons a COPY, and a Sync.
pub fn copy_fail_and_sync() -> BitArray {
  <<"f", 34:32, "the client abandoned the COPY":utf8, 0, "S", 4:32>>
}

/// The bytes of the CopyFail that refuses a COPY, and a Sync.
pub fn copy_refusal_and_sync() -> BitArray {
  <<"f", 39:32, "COPY is not supported by this step":utf8, 0, "S", 4:32>>
}

/// What the step gives for its ReadyForQuery, with no asynchronous
/// message.
pub fn finished(
  result: Result(CopyResult, Failure),
  status: TransactionStatus,
) -> Seen {
  Finished(Outcome(result:, status:, asynchronous_messages: []))
}

/// `count` bytes of the letter a.
pub fn repeated_byte(count: Int) -> BitArray {
  list.repeat(<<"a":utf8>>, count) |> bit_array.concat
}

/// A copy step for `COPY ... FROM STDIN` after its CopyInResponse.
pub fn started_copy_in() -> CopyState {
  let start = query.start_copy("COPY t FROM STDIN", CopyFrom)
  list.fold(copy_in_start(), start.state, take_message)
}

fn take_message(state: CopyState, input: Input) -> CopyState {
  case input {
    FromServer(message) -> stepped_state(query.step_copy(state, message), state)
    _app_call -> state
  }
}

fn stepped_state(
  step: Result(query.CopyStep, query.UnexpectedMessage),
  before: CopyState,
) -> CopyState {
  case step {
    Ok(query.CopyStarted(state)) -> state
    Ok(query.CopyWait(state)) -> state
    _other -> before
  }
}
