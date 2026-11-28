//// The query steps of the PostgreSQL wire protocol, as pure state machines:
//// prepare a statement, run a prepared statement, prepare and run in one
//// round trip, run a simple query with the simple query protocol, and run a
//// COPY that streams rows into a table or out of one.
////
//// Each step has a start function and a step function. The start function
//// gives the messages to send and the first state. The step function takes
//// the state and one message from the server. It gives the next state, with
//// the messages to send if there are any, or the finished outcome. Nothing
//// here touches a socket. The message flows are the ones of the PostgreSQL
//// documentation, chapter "Frontend/Backend Protocol", section "Message
//// Flow".
////
//// Each step reads up to ReadyForQuery, also after an error and after a
//// COPY that it refuses, so that the connection can take the next command.
//// Only the copy step takes a COPY; the other steps refuse it.
//// The outcome gives the transaction status of that ReadyForQuery. Each
//// ParameterStatus, NoticeResponse and NotificationResponse that arrives
//// during a step comes back with the outcome, in the order of arrival.
//// A message that the flow does not allow where it arrives is an
//// `UnexpectedMessage`, with the phase of the step.
////
//// An ErrorResponse with the severity `FATAL` or `PANIC` ends the step at
//// once: the server closes the connection and sends no ReadyForQuery.
////
//// This module holds what every step gives: its start, its steps, its outcome
//// and its failure. The steps of each protocol live in the modules beside it:
//// `extended_query`, `simple_query` and `copy_step`. They share the state
//// machine of `machine`, which reads each message of the server with
//// `receive`.
////
//// This module is internal to dream_postgres.

import dream_postgres/driver/cell.{
  type ColumnDescription, type CommandResult, type ServerReport,
  type TransactionStatus,
}
import dream_postgres/driver/message.{type BackendMessage, type FrontendMessage}
import gleam/option.{type Option, Some}

/// A message that the server can send at any time, and that a step gives
/// back with its outcome (docs, "Asynchronous Operations").
pub type AsynchronousMessage {
  /// A ParameterStatus: a run-time parameter has this value now.
  ParameterChanged(name: String, value: String)
  /// A NoticeResponse, with every field the server sent.
  Notice(report: ServerReport)
  /// A NotificationResponse: a `NOTIFY` on a channel that the connection
  /// listens to.
  Notification(process_id: Int, channel: String, payload: String)
}

/// What a step waits for next. An `UnexpectedMessage` names it.
pub type Phase {
  /// ParseComplete, the answer to Parse.
  AwaitingParseComplete
  /// ParameterDescription, the first answer to a Describe of a statement.
  AwaitingParameterDescription
  /// RowDescription or NoData, the second answer to a Describe of a
  /// statement.
  AwaitingStatementColumns
  /// BindComplete, the answer to Bind.
  AwaitingBindComplete
  /// CloseComplete, the answer to Close.
  AwaitingCloseComplete
  /// RowDescription or NoData, the answer to a Describe of a portal.
  AwaitingPortalColumns
  /// DataRow, or the end of an Execute: CommandComplete,
  /// EmptyQueryResponse, or the start of a COPY.
  ReadingExecuteRows
  /// The start of the next result of a simple query: RowDescription,
  /// CommandComplete, EmptyQueryResponse, the start of a COPY, or the
  /// ReadyForQuery after the last statement.
  AwaitingStatementResult
  /// DataRow or CommandComplete, after the RowDescription of a statement of
  /// a simple query.
  ReadingSimpleQueryRows
  /// CopyData or CopyDone from the server: the rows of a
  /// `COPY ... TO STDOUT`, or of a COPY that the step refused.
  ReadingCopyOut
  /// The CommandComplete or the ErrorResponse that ends a COPY that the
  /// step refused, or the end of the rows of a `COPY ... TO STDOUT`.
  AwaitingCopyComplete
  /// The server reads the CopyData of a `COPY ... FROM STDIN`, up to the
  /// CommandComplete or the ErrorResponse that ends it.
  CopyingIn
  /// ReadyForQuery, after the last answer of the step.
  AwaitingReadyForQuery
  /// ReadyForQuery, after an ErrorResponse.
  AwaitingReadyForQueryAfterError
}

/// A message that the protocol does not allow in the phase where it came.
/// The connection is not in a known state after it.
pub type UnexpectedMessage {
  UnexpectedMessage(
    /// The message, as it came.
    message: BackendMessage,
    /// What the step waited for.
    phase: Phase,
    /// The asynchronous messages that came before it, in order.
    asynchronous_messages: List(AsynchronousMessage),
  )
}

/// Why a step that read up to ReadyForQuery did not succeed.
pub type Failure {
  /// The server sent an ErrorResponse, with every field.
  ServerError(report: ServerReport)
  /// The server started a COPY, which a query step does not do, or a COPY
  /// of the other direction than the copy step's. The step refused it and
  /// read up to ReadyForQuery. The error is the ErrorResponse that came
  /// after the COPY started, if one came: for a `COPY ... FROM STDIN` it is
  /// the server's answer to the CopyFail.
  CopyNotSupported(error: Option(ServerReport))
}

/// The result of one statement: its result columns and its command result.
pub type StatementResult {
  StatementResult(
    /// The columns of the RowDescription, or none for a statement that
    /// returns no rows.
    columns: List(ColumnDescription),
    /// The rows, the command tag and the row count of the tag.
    result: CommandResult,
  )
}

/// Why a simple query did not succeed, with the results of the statements that
/// were done before.
pub type SimpleQueryFailure {
  SimpleQueryFailure(completed: List(StatementResult), failure: Failure)
}

/// The finished outcome of a step: what it gave, the transaction status of
/// its ReadyForQuery, and the asynchronous messages that came during it.
pub type Outcome(value, failure) {
  Outcome(
    result: Result(value, failure),
    status: TransactionStatus,
    asynchronous_messages: List(AsynchronousMessage),
  )
}

/// The start of a step: the messages to send, in order, and the first
/// state.
pub type Start(state) {
  Start(messages: List(FrontendMessage), state: state)
}

/// The start of a step of a driver housekeeping statement: its bytes,
/// which cannot fail to encode, and the first state.
pub type HousekeepingStart(state) {
  HousekeepingStart(bytes: BitArray, state: state)
}

/// What a step gives after one message from the server.
pub type Step(state, outcome) {
  /// Send these bytes, then wait for the next message. A step sends only
  /// messages that the driver writes itself (CopyFail, CopyDone, Sync), so
  /// they come as bytes that cannot fail to encode.
  Send(bytes: BitArray, state: state)
  /// Wait for the next message.
  Wait(state: state)
  /// The step read its ReadyForQuery.
  Finished(outcome: outcome)
  /// The server sent an ErrorResponse with the severity `FATAL` or `PANIC`
  /// and closes the connection.
  ConnectionEnded(
    report: ServerReport,
    asynchronous_messages: List(AsynchronousMessage),
  )
}

/// The direction of a COPY that the copy step takes.
pub type CopyDirection {
  /// A `COPY ... FROM STDIN`: rows from the app into a table.
  CopyFrom
  /// A `COPY ... TO STDOUT`: rows from a table to the app.
  CopyTo
}

/// What a copy step gave, when it read its ReadyForQuery with no error.
pub type CopyResult {
  /// The COPY ended. `count` is the number of rows of its CommandComplete:
  /// the rows that the server stored, or the rows that it sent.
  CopyCompleted(count: Int)
  /// The statement did not start the COPY of the step's direction, and ran
  /// to its end: a statement that is not a COPY, with its rows as text
  /// cells, or a `COPY ... TO STDOUT` in a step for `COPY ... FROM STDIN`,
  /// with its tag and none of its rows, which the step dropped.
  NoCopyStarted(result: CommandResult)
}

/// The server error of a failure, if it has one.
///
/// ## Parameters
///
/// - `failure`: the failure of a step
///
/// ## Returns
///
/// - `Some(report)`: the ErrorResponse that ended the step
/// - `None`: a refused COPY that ended without an error
pub fn failure_report(failure: Failure) -> Option(ServerReport) {
  case failure {
    ServerError(report:) -> Some(report)
    CopyNotSupported(error:) -> error
  }
}

/// The severities of an ErrorResponse after which the server closes the
/// connection.
pub const connection_ending_severities = ["FATAL", "PANIC"]
