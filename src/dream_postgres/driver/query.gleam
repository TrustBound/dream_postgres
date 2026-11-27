//// The query steps of the PostgreSQL wire protocol, as pure state machines:
//// prepare a statement, run a prepared statement, prepare and run in one
//// round trip, run a script with the simple query protocol, and run a
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
//// This module is internal to dream_postgres.

import dream_postgres/driver/encode.{
  copy_abandonment, copy_data_messages, copy_done, copy_refusal, sync,
}
import dream_postgres/driver/housekeeping_sql.{type HousekeepingSql}
import dream_postgres/driver/message.{
  type BackendMessage, type FrontendMessage, type ResultColumn, Bind,
  BindComplete, Close, CloseComplete, CommandComplete, CopyBothResponse,
  CopyDataFromServer, CopyDoneFromServer, CopyInResponse, CopyOutResponse,
  DataRow, Describe, EmptyQueryResponse, ErrorResponse, Execute, NoData,
  NoticeResponse, NotificationResponse, ParameterDescriptions, ParameterStatus,
  Parse, ParseComplete, Portal, Query, ReadyForQuery, RowDescription, Statement,
  Sync,
}
import dream_postgres/internal/cell.{
  type Cell, type ColumnDescription, type CommandResult, type Format,
  type ParameterDescription, type ServerReport, type StatementDescription,
  type TransactionStatus, Binary, BinaryFormat, CommandResult, Null,
  StatementDescription, Text, TextFormat,
}
import gleam/bool.{guard}
import gleam/int.{parse}
import gleam/list.{contains, last, map, reverse, strict_zip}
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string.{split, split_once}

/// The commands whose tag ends with a row count (docs, "CommandComplete").
const counted_commands = [
  "INSERT", "UPDATE", "DELETE", "MERGE", "SELECT", "MOVE", "FETCH", "COPY",
]

/// The severities of an ErrorResponse after which the server closes the
/// connection.
const connection_ending_severities = ["FATAL", "PANIC"]

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
  /// The start of the next result of a script: RowDescription,
  /// CommandComplete, EmptyQueryResponse, the start of a COPY, or the
  /// ReadyForQuery after the last statement.
  AwaitingStatementResult
  /// DataRow or CommandComplete, after the RowDescription of a statement of
  /// a script.
  ReadingScriptRows
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

/// Why a script did not succeed, with the results of the statements that
/// were done before.
pub type ScriptFailure {
  ScriptFailure(completed: List(StatementResult), failure: Failure)
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

/// The state of a prepare step.
pub opaque type PrepareState {
  PrepareState(machine: Machine)
}

/// The state of a run step.
pub opaque type RunState {
  RunState(machine: Machine)
}

/// The state of a step that prepares and runs in one round trip.
pub opaque type PrepareAndRunState {
  PrepareAndRunState(machine: Machine)
}

/// The state of a simple query step.
pub opaque type SimpleQueryState {
  SimpleQueryState(machine: Machine)
}

/// The state of a copy step.
pub opaque type CopyState {
  CopyState(machine: Machine)
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

/// What a copy step gives after one message from the server.
pub type CopyStep {
  /// The server started the COPY of the step's direction. In a
  /// `COPY ... FROM STDIN` it now reads CopyData; in a
  /// `COPY ... TO STDOUT` the rows follow.
  CopyStarted(state: CopyState)
  /// One row of a `COPY ... TO STDOUT`: the data of one CopyData, in the
  /// format of the COPY.
  CopyRow(row: BitArray, state: CopyState)
  /// Send these bytes, then wait for the next message.
  CopySend(bytes: BitArray, state: CopyState)
  /// Wait for the next message.
  CopyWait(state: CopyState)
  /// The step read its ReadyForQuery.
  CopyFinished(outcome: Outcome(CopyResult, Failure))
  /// The server sent an ErrorResponse with the severity `FATAL` or `PANIC`
  /// and closes the connection.
  CopyConnectionEnded(
    report: ServerReport,
    asynchronous_messages: List(AsynchronousMessage),
  )
}

/// What a step does with a COPY that the server starts.
type CopyMode {
  /// A query step refuses every COPY.
  RefuseCopy
  /// The copy step takes a COPY of this direction, and refuses the others.
  ExpectCopy(direction: CopyDirection)
}

/// What the last message started in a copy step, for the step to tell.
type CopySignal {
  NoCopySignal
  CopyBeganSignal
  CopyRowSignal(row: BitArray)
}

type QueryProtocol {
  ExtendedProtocol
  SimpleProtocol
}

/// The formats that tag the cells of each DataRow.
type CellFormats {
  /// The result formats of a Bind, by the rule of the protocol: none means
  /// text for each column, one means that format for each column, and more
  /// means one for each column.
  BoundFormats(List(Format))
  /// One format for each column, from a RowDescription.
  ColumnFormats(List(Format))
}

/// The state that every step shares. The lists that grow during the step
/// have their newest item first.
type Machine {
  Machine(
    protocol: QueryProtocol,
    phase: Phase,
    next_phases: List(Phase),
    parameters: List(ParameterDescription),
    columns: List(ColumnDescription),
    cell_formats: CellFormats,
    rows: List(List(Cell)),
    tag: String,
    count: Int,
    results: List(StatementResult),
    error: Option(ServerReport),
    copy_refused: Bool,
    messages: List(AsynchronousMessage),
    copy_mode: CopyMode,
    /// The COPY of the copy step's direction started.
    copy_began: Bool,
    /// The step sent the CopyDone or the CopyFail, and its Sync, that end
    /// a `COPY ... FROM STDIN`, or the server ended it with an error.
    copy_in_ended: Bool,
    /// The app gave up the COPY: a `COPY ... FROM STDIN` gets a CopyFail,
    /// and the rows of a `COPY ... TO STDOUT` are dropped.
    copy_abandoned: Bool,
    copy_signal: CopySignal,
  )
}

/// What the shared state machine gives after one message.
type Transition {
  Continue(send: BitArray, machine: Machine)
  Ready(status: TransactionStatus, machine: Machine)
  Ended(report: ServerReport, machine: Machine)
}

/// Starts to prepare a statement: Parse, Describe of the statement, and
/// Sync. The outcome describes each parameter and each result column
/// before any Bind. A statement that returns no rows has no columns.
///
/// ## Parameters
///
/// - `statement`: the name of the statement, or the empty name for the
///   unnamed statement
/// - `query`: the SQL of one statement
/// - `parameter_type_ids`: the type OIDs of the first parameters, where 0
///   leaves a type for the server to choose
///
/// ## Returns
///
/// The messages to send and the state for `step_prepare`.
pub fn start_prepare(
  statement: String,
  query: String,
  parameter_type_ids: List(Int),
) -> Start(PrepareState) {
  start_prepare_closing([], statement, query, parameter_type_ids)
}

/// Starts to prepare a statement, after a Close of each named statement
/// in `closing`, in the same round trip: Close for each, Parse, Describe
/// of the statement, and Sync. The server answers each Close with
/// CloseComplete, also for a name that has no statement.
///
/// ## Parameters
///
/// - `closing`: the names of the statements to close first
/// - `statement`: the name of the statement to prepare
/// - `query`: the SQL of one statement
/// - `parameter_type_ids`: the type OIDs of the first parameters, where 0
///   leaves a type for the server to choose
///
/// ## Returns
///
/// The messages to send and the state for `step_prepare`.
pub fn start_prepare_closing(
  closing: List(String),
  statement: String,
  query: String,
  parameter_type_ids: List(Int),
) -> Start(PrepareState) {
  let #(first_phase, next_phases) = case closing {
    [] -> #(AwaitingParseComplete, [
      AwaitingParameterDescription,
      AwaitingStatementColumns,
    ])
    [_first, ..others] -> #(
      AwaitingCloseComplete,
      list.append(map(others, close_phase), [
        AwaitingParseComplete,
        AwaitingParameterDescription,
        AwaitingStatementColumns,
      ]),
    )
  }
  let closes = map(closing, close_message)
  let machine =
    new_machine(ExtendedProtocol, first_phase, next_phases, BoundFormats([]))
  Start(
    messages: list.append(closes, [
      Parse(statement:, query:, parameter_type_ids:),
      Describe(Statement(statement)),
      Sync,
    ]),
    state: PrepareState(machine),
  )
}

fn close_phase(_name: String) -> Phase {
  AwaitingCloseComplete
}

fn close_message(name: String) -> FrontendMessage {
  Close(Statement(name))
}

/// Reads one message from the server in a prepare step.
///
/// ## Parameters
///
/// - `state`: the state from `start_prepare` or from the last step
/// - `message`: the message from the server
///
/// ## Returns
///
/// - `Ok(step)`: what to do next, or the outcome with the description of
///   the statement
/// - `Error(UnexpectedMessage)`: the protocol does not allow the message
///   here
pub fn step_prepare(
  state: PrepareState,
  message: BackendMessage,
) -> Result(
  Step(PrepareState, Outcome(StatementDescription, ServerReport)),
  UnexpectedMessage,
) {
  receive(state.machine, message)
  |> result.map(to_step(_, PrepareState, prepare_outcome))
}

/// Starts to run a prepared statement: Bind to the unnamed portal, Execute
/// with no row limit, and Sync.
///
/// ## Parameters
///
/// - `statement`: the name of the prepared statement, or the empty name
///   for the unnamed statement
/// - `parameters`: each parameter's cell; its form gives its format
/// - `result_formats`: the result formats, by the rule of Bind: none for
///   text in each column, one for that format in each column, or one for
///   each column. The step tags each cell with the format of its column.
///
/// ## Returns
///
/// The messages to send and the state for `step_run`.
pub fn start_run(
  statement: String,
  parameters: List(Cell),
  result_formats: List(Format),
) -> Start(RunState) {
  let machine =
    new_machine(
      ExtendedProtocol,
      AwaitingBindComplete,
      [ReadingExecuteRows],
      BoundFormats(result_formats),
    )
  Start(
    messages: [
      Bind(portal: "", statement:, parameters:, result_formats:),
      Execute(portal: "", row_limit: 0),
      Sync,
    ],
    state: RunState(machine),
  )
}

/// Reads one message from the server in a run step. A statement with an
/// empty query gives no rows, the empty tag and the count 0.
///
/// ## Parameters
///
/// - `state`: the state from `start_run` or from the last step
/// - `message`: the message from the server
///
/// ## Returns
///
/// - `Ok(step)`: what to do next, or the outcome with the command result
/// - `Error(UnexpectedMessage)`: the protocol does not allow the message
///   here
pub fn step_run(
  state: RunState,
  message: BackendMessage,
) -> Result(Step(RunState, Outcome(CommandResult, Failure)), UnexpectedMessage) {
  receive(state.machine, message)
  |> result.map(to_step(_, RunState, run_outcome))
}

/// Starts to prepare and run one statement in one round trip, with the
/// unnamed statement and the unnamed portal: Parse, Bind, Describe of the
/// portal, Execute with no row limit, and Sync. The result formats must be
/// chosen before the server describes the columns.
///
/// ## Parameters
///
/// - `query`: the SQL of one statement
/// - `parameter_type_ids`: the type OIDs of the first parameters, where 0
///   leaves a type for the server to choose
/// - `parameters`: each parameter's cell; its form gives its format
/// - `result_formats`: the result formats, by the rule of Bind
///
/// ## Returns
///
/// The messages to send and the state for `step_prepare_and_run`.
pub fn start_prepare_and_run(
  query: String,
  parameter_type_ids: List(Int),
  parameters: List(Cell),
  result_formats: List(Format),
) -> Start(PrepareAndRunState) {
  Start(
    messages: [
      Parse(statement: "", query:, parameter_type_ids:),
      Bind(portal: "", statement: "", parameters:, result_formats:),
      Describe(Portal("")),
      Execute(portal: "", row_limit: 0),
      Sync,
    ],
    state: prepare_and_run_state(result_formats),
  )
}

/// Starts to prepare and run a driver housekeeping statement in one round
/// trip, as `start_prepare_and_run` with no parameter and text results.
///
/// ## Parameters
///
/// - `sql`: the housekeeping statement
///
/// ## Returns
///
/// The bytes to send and the state for `step_prepare_and_run`.
pub fn start_housekeeping_run(
  sql: HousekeepingSql,
) -> HousekeepingStart(PrepareAndRunState) {
  HousekeepingStart(
    bytes: housekeeping_sql.prepare_and_run_messages(sql),
    state: prepare_and_run_state([]),
  )
}

fn prepare_and_run_state(result_formats: List(Format)) -> PrepareAndRunState {
  let next_phases = [
    AwaitingBindComplete,
    AwaitingPortalColumns,
    ReadingExecuteRows,
  ]
  new_machine(
    ExtendedProtocol,
    AwaitingParseComplete,
    next_phases,
    BoundFormats(result_formats),
  )
  |> PrepareAndRunState
}

/// Reads one message from the server in a step that prepares and runs in
/// one round trip. Each cell has the format that the RowDescription of the
/// portal gives for its column.
///
/// ## Parameters
///
/// - `state`: the state from `start_prepare_and_run` or from the last step
/// - `message`: the message from the server
///
/// ## Returns
///
/// - `Ok(step)`: what to do next, or the outcome with the columns of the
///   portal and the command result
/// - `Error(UnexpectedMessage)`: the protocol does not allow the message
///   here
pub fn step_prepare_and_run(
  state: PrepareAndRunState,
  message: BackendMessage,
) -> Result(
  Step(PrepareAndRunState, Outcome(StatementResult, Failure)),
  UnexpectedMessage,
) {
  receive(state.machine, message)
  |> result.map(to_step(_, PrepareAndRunState, prepare_and_run_outcome))
}

/// Starts to run a script of one or more statements with the simple query
/// protocol: one Query.
///
/// ## Parameters
///
/// - `script`: the SQL statements
///
/// ## Returns
///
/// The messages to send and the state for `step_simple_query`.
pub fn start_simple_query(script: String) -> Start(SimpleQueryState) {
  Start(messages: [Query(script)], state: simple_query_state())
}

/// Starts to run a driver housekeeping statement with the simple query
/// protocol, as `start_simple_query`.
///
/// ## Parameters
///
/// - `sql`: the housekeeping statement
///
/// ## Returns
///
/// The bytes to send and the state for `step_simple_query`.
pub fn start_housekeeping_script(
  sql: HousekeepingSql,
) -> HousekeepingStart(SimpleQueryState) {
  HousekeepingStart(
    bytes: housekeeping_sql.query_message(sql),
    state: simple_query_state(),
  )
}

fn simple_query_state() -> SimpleQueryState {
  new_machine(SimpleProtocol, AwaitingStatementResult, [], ColumnFormats([]))
  |> SimpleQueryState
}

/// Reads one message from the server in a simple query step. The outcome
/// has one result for each statement, in order, with each cell in the
/// format that its RowDescription gives (text, except for a `FETCH` from a
/// binary cursor). An empty script, with only spaces or comments, gets an
/// EmptyQueryResponse and gives no results. After an error, the results of
/// the statements before it come with the failure.
///
/// ## Parameters
///
/// - `state`: the state from `start_simple_query` or from the last step
/// - `message`: the message from the server
///
/// ## Returns
///
/// - `Ok(step)`: what to do next, or the outcome with the result of each
///   statement
/// - `Error(UnexpectedMessage)`: the protocol does not allow the message
///   here
pub fn step_simple_query(
  state: SimpleQueryState,
  message: BackendMessage,
) -> Result(
  Step(SimpleQueryState, Outcome(List(StatementResult), ScriptFailure)),
  UnexpectedMessage,
) {
  receive(state.machine, message)
  |> result.map(to_step(_, SimpleQueryState, simple_query_outcome))
}

/// Starts a copy step: Parse, Bind and Execute of one statement on the
/// unnamed statement and portal, and Sync. The extended protocol takes one
/// statement only, so a script cannot hide a second one. The server reads
/// past the Sync during a `COPY ... FROM STDIN`, so the step sends a new
/// one when the COPY ends.
///
/// A COPY of the other direction is refused as the query steps refuse it,
/// and a statement that is not a COPY runs to its end.
///
/// ## Parameters
///
/// - `query`: the SQL of one COPY statement
/// - `direction`: the direction that the COPY must have
///
/// ## Returns
///
/// The messages to send and the state for `step_copy`.
pub fn start_copy(query: String, direction: CopyDirection) -> Start(CopyState) {
  let machine =
    Machine(
      ..new_machine(
        ExtendedProtocol,
        AwaitingParseComplete,
        [AwaitingBindComplete, ReadingExecuteRows],
        BoundFormats([]),
      ),
      copy_mode: ExpectCopy(direction),
    )
  Start(
    messages: [
      Parse(statement: "", query:, parameter_type_ids: []),
      Bind(portal: "", statement: "", parameters: [], result_formats: []),
      Execute(portal: "", row_limit: 0),
      Sync,
    ],
    state: CopyState(machine),
  )
}

/// Reads one message from the server in a copy step. After an error in a
/// `COPY ... FROM STDIN` the step sends the Sync that the server waits for.
///
/// ## Parameters
///
/// - `state`: the state from `start_copy` or from the last step
/// - `message`: the message from the server
///
/// ## Returns
///
/// - `Ok(step)`: the start of the COPY, a row, what to do next, or the
///   outcome
/// - `Error(UnexpectedMessage)`: the protocol does not allow the message
///   here
pub fn step_copy(
  state: CopyState,
  message: BackendMessage,
) -> Result(CopyStep, UnexpectedMessage) {
  receive(state.machine, message)
  |> result.map(to_copy_step)
}

/// Whether the server reads CopyData now: the `COPY ... FROM STDIN`
/// started, and neither side ended it.
///
/// ## Parameters
///
/// - `state`: the state of a copy step
///
/// ## Returns
///
/// `True` while CopyData may go to the server.
pub fn accepts_copy_data(state: CopyState) -> Bool {
  state.machine.phase == CopyingIn && !state.machine.copy_in_ended
}

/// The bytes of the CopyData messages for a chunk of a
/// `COPY ... FROM STDIN`. Send them only while `accepts_copy_data` is
/// `True`.
///
/// ## Parameters
///
/// - `chunk`: bytes of the COPY data stream, in the format of the COPY
///
/// ## Returns
///
/// The bytes to send.
pub fn copy_data(chunk: BitArray) -> BitArray {
  copy_data_messages(chunk)
}

/// The app is done with the COPY. A `COPY ... FROM STDIN` that reads data
/// gets CopyDone and Sync, so the server stores the rows. In any other
/// phase the step abandons the COPY, as `abandon_copy` does: the app wants
/// no more rows.
///
/// ## Parameters
///
/// - `state`: the state of a copy step
///
/// ## Returns
///
/// The next state and the bytes to send, which may be none.
pub fn finish_copy(state: CopyState) -> #(CopyState, BitArray) {
  case accepts_copy_data(state) {
    True -> #(CopyState(Machine(..state.machine, copy_in_ended: True)), <<
      copy_done():bits,
      sync():bits,
    >>)
    False -> abandon_copy(state)
  }
}

/// The app gives up the COPY. A `COPY ... FROM STDIN` that reads data gets
/// CopyFail and Sync, so the server stores no row of it. One that has not
/// started gets them when it starts. The rows of a `COPY ... TO STDOUT`
/// are dropped up to its end, because the protocol has no message that
/// stops it.
///
/// ## Parameters
///
/// - `state`: the state of a copy step
///
/// ## Returns
///
/// The next state and the bytes to send, which may be none.
pub fn abandon_copy(state: CopyState) -> #(CopyState, BitArray) {
  let machine = Machine(..state.machine, copy_abandoned: True)
  case accepts_copy_data(state) {
    True -> #(CopyState(Machine(..machine, copy_in_ended: True)), <<
      copy_abandonment():bits,
      sync():bits,
    >>)
    False -> #(CopyState(machine), <<>>)
  }
}

/// What the deadline of a copy step does: the rows of a
/// `COPY ... TO STDOUT` are dropped up to its end, as `abandon_copy` does,
/// so that the server can act on the cancel. A `COPY ... FROM STDIN` stays
/// as it is until the cancel reached the server; then `abandon_copy` ends
/// it.
///
/// ## Parameters
///
/// - `state`: the state of a copy step
///
/// ## Returns
///
/// The next state and the bytes to send, which are none.
pub fn stop_at_deadline(state: CopyState) -> #(CopyState, BitArray) {
  case state.machine.copy_mode {
    ExpectCopy(CopyTo) -> abandon_copy(state)
    _ -> #(state, <<>>)
  }
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

fn new_machine(
  protocol: QueryProtocol,
  phase: Phase,
  next_phases: List(Phase),
  cell_formats: CellFormats,
) -> Machine {
  Machine(
    protocol:,
    phase:,
    next_phases:,
    parameters: [],
    columns: [],
    cell_formats:,
    rows: [],
    tag: "",
    count: 0,
    results: [],
    error: None,
    copy_refused: False,
    messages: [],
    copy_mode: RefuseCopy,
    copy_began: False,
    copy_in_ended: False,
    copy_abandoned: False,
    copy_signal: NoCopySignal,
  )
}

fn to_step(
  transition: Transition,
  wrap_state: fn(Machine) -> state,
  build_outcome: fn(Machine, TransactionStatus) -> outcome,
) -> Step(state, outcome) {
  case transition {
    Continue(send: <<>>, machine:) -> Wait(wrap_state(machine))
    Continue(send:, machine:) -> Send(send, wrap_state(machine))
    Ready(status:, machine:) -> Finished(build_outcome(machine, status))
    Ended(report:, machine:) ->
      ConnectionEnded(report, reverse(machine.messages))
  }
}

fn to_copy_step(transition: Transition) -> CopyStep {
  case transition {
    Continue(send:, machine:) -> continued_copy(send, machine)
    Ready(status:, machine:) -> CopyFinished(copy_outcome(machine, status))
    Ended(report:, machine:) ->
      CopyConnectionEnded(report, reverse(machine.messages))
  }
}

/// Tells the start of the COPY or a row, if the last message gave one,
/// else sends or waits.
fn continued_copy(send: BitArray, machine: Machine) -> CopyStep {
  let state = CopyState(Machine(..machine, copy_signal: NoCopySignal))
  case machine.copy_signal, send {
    CopyBeganSignal, _ -> CopyStarted(state)
    CopyRowSignal(row:), _ -> CopyRow(row, state)
    NoCopySignal, <<>> -> CopyWait(state)
    NoCopySignal, _ -> CopySend(send, state)
  }
}

fn copy_outcome(
  machine: Machine,
  status: TransactionStatus,
) -> Outcome(CopyResult, Failure) {
  let copy_result = case machine.copy_began {
    True -> CopyCompleted(machine.count)
    False -> NoCopyStarted(command_result(machine))
  }
  // A refused COPY that ended with no error is a COPY TO STDOUT that ran
  // to its end: it completed, as a statement that is not a COPY does.
  case machine.copy_refused, machine.error {
    True, None -> Ok(copy_result)
    _, _ -> step_result(machine, copy_result)
  }
  |> outcome(machine, status, _)
}

/// A prepare step fails only with the server's error: none of its phases
/// takes the start of a COPY, so it never refuses one.
fn prepare_outcome(
  machine: Machine,
  status: TransactionStatus,
) -> Outcome(StatementDescription, ServerReport) {
  let description =
    StatementDescription(
      parameters: machine.parameters,
      columns: machine.columns,
    )
  case machine.error {
    Some(report) -> Error(report)
    None -> Ok(description)
  }
  |> outcome(machine, status, _)
}

fn run_outcome(
  machine: Machine,
  status: TransactionStatus,
) -> Outcome(CommandResult, Failure) {
  command_result(machine)
  |> step_result(machine, _)
  |> outcome(machine, status, _)
}

fn prepare_and_run_outcome(
  machine: Machine,
  status: TransactionStatus,
) -> Outcome(StatementResult, Failure) {
  StatementResult(columns: machine.columns, result: command_result(machine))
  |> step_result(machine, _)
  |> outcome(machine, status, _)
}

fn simple_query_outcome(
  machine: Machine,
  status: TransactionStatus,
) -> Outcome(List(StatementResult), ScriptFailure) {
  let completed = reverse(machine.results)
  step_result(machine, completed)
  |> result.map_error(ScriptFailure(completed, _))
  |> outcome(machine, status, _)
}

fn outcome(
  machine: Machine,
  status: TransactionStatus,
  step_result: Result(value, failure),
) -> Outcome(value, failure) {
  Outcome(
    result: step_result,
    status:,
    asynchronous_messages: reverse(machine.messages),
  )
}

fn step_result(machine: Machine, value: value) -> Result(value, Failure) {
  case machine.copy_refused, machine.error {
    True, error -> Error(CopyNotSupported(error:))
    False, Some(report) -> Error(ServerError(report:))
    False, None -> Ok(value)
  }
}

fn command_result(machine: Machine) -> CommandResult {
  CommandResult(
    rows: reverse(machine.rows),
    tag: machine.tag,
    count: machine.count,
  )
}

/// Takes the messages that every phase allows, then gives the others to
/// the handler of the phase.
fn receive(
  machine: Machine,
  message: BackendMessage,
) -> Result(Transition, UnexpectedMessage) {
  case message {
    ParameterStatus(name:, value:) ->
      Ok(keep(machine, ParameterChanged(name:, value:)))
    NoticeResponse(report:) -> Ok(keep(machine, Notice(report:)))
    NotificationResponse(process_id:, channel:, payload:) ->
      Ok(keep(machine, Notification(process_id:, channel:, payload:)))
    ErrorResponse(report:) -> server_error(machine, report)
    _ -> receive_in_phase(machine, message)
  }
}

fn receive_in_phase(
  machine: Machine,
  message: BackendMessage,
) -> Result(Transition, UnexpectedMessage) {
  case machine.phase {
    AwaitingParseComplete -> parse_answer(machine, message)
    AwaitingParameterDescription -> parameter_answer(machine, message)
    AwaitingStatementColumns | AwaitingPortalColumns ->
      columns_answer(machine, message)
    AwaitingBindComplete -> bind_answer(machine, message)
    AwaitingCloseComplete -> close_answer(machine, message)
    ReadingExecuteRows -> execute_answer(machine, message)
    AwaitingStatementResult -> statement_answer(machine, message)
    ReadingScriptRows -> script_row_answer(machine, message)
    ReadingCopyOut -> copy_out_answer(machine, message)
    AwaitingCopyComplete | CopyingIn -> copy_end_answer(machine, message)
    AwaitingReadyForQuery | AwaitingReadyForQueryAfterError ->
      ready_answer(machine, message)
  }
}

fn keep(machine: Machine, message: AsynchronousMessage) -> Transition {
  wait_with(Machine(..machine, messages: [message, ..machine.messages]))
}

/// An ErrorResponse ends the work of the step: the server skips to the
/// Sync, or to the end of the Query, and sends ReadyForQuery. During a
/// `COPY ... FROM STDIN` the server read the Sync of the Execute already,
/// so the step sends a new one, unless it sent the one after its CopyDone
/// or CopyFail.
fn server_error(
  machine: Machine,
  report: ServerReport,
) -> Result(Transition, UnexpectedMessage) {
  let ends_connection = contains(connection_ending_severities, report.severity)
  use <- guard(ends_connection, Ok(Ended(report:, machine:)))
  let after_error = machine.phase == AwaitingReadyForQueryAfterError
  use <- guard(after_error, unexpected(machine, ErrorResponse(report:)))
  let send = case accepts_copy_data(CopyState(machine)) {
    True -> sync()
    False -> <<>>
  }
  Machine(
    ..machine,
    phase: AwaitingReadyForQueryAfterError,
    error: Some(report),
    copy_in_ended: True,
  )
  |> Continue(send:, machine: _)
  |> Ok
}

fn parse_answer(
  machine: Machine,
  message: BackendMessage,
) -> Result(Transition, UnexpectedMessage) {
  case message {
    ParseComplete -> Ok(wait_with(advance(machine)))
    _ -> unexpected(machine, message)
  }
}

fn parameter_answer(
  machine: Machine,
  message: BackendMessage,
) -> Result(Transition, UnexpectedMessage) {
  case message {
    ParameterDescriptions(parameters:) ->
      Ok(wait_with(advance(Machine(..machine, parameters:))))
    _ -> unexpected(machine, message)
  }
}

fn columns_answer(
  machine: Machine,
  message: BackendMessage,
) -> Result(Transition, UnexpectedMessage) {
  case message {
    RowDescription(columns:) ->
      Ok(wait_with(advance(with_columns(machine, columns))))
    NoData -> Ok(wait_with(advance(with_columns(machine, []))))
    _ -> unexpected(machine, message)
  }
}

fn close_answer(
  machine: Machine,
  message: BackendMessage,
) -> Result(Transition, UnexpectedMessage) {
  case message {
    CloseComplete -> Ok(wait_with(advance(machine)))
    _ -> unexpected(machine, message)
  }
}

fn bind_answer(
  machine: Machine,
  message: BackendMessage,
) -> Result(Transition, UnexpectedMessage) {
  case message {
    BindComplete -> Ok(wait_with(advance(machine)))
    _ -> unexpected(machine, message)
  }
}

/// The answers to an Execute, which end with exactly one of
/// CommandComplete, EmptyQueryResponse, ErrorResponse or the start of a
/// COPY. An empty query gives the empty tag and the count 0.
fn execute_answer(
  machine: Machine,
  message: BackendMessage,
) -> Result(Transition, UnexpectedMessage) {
  case message {
    DataRow(values:) -> add_row(machine, values)
    CommandComplete(tag:) ->
      complete_command(machine, tag)
      |> result.map(advance)
      |> result.map(wait_with)
    EmptyQueryResponse -> Ok(wait_with(advance(machine)))
    _ -> copy_answer(machine, message)
  }
}

fn statement_answer(
  machine: Machine,
  message: BackendMessage,
) -> Result(Transition, UnexpectedMessage) {
  case message {
    RowDescription(columns:) -> {
      let described = with_columns(machine, columns)
      Ok(wait_with(Machine(..described, phase: ReadingScriptRows)))
    }
    CommandComplete(tag:) -> finish_statement(machine, tag)
    EmptyQueryResponse -> Ok(wait_with(machine))
    ReadyForQuery(status:) -> Ok(Ready(status:, machine:))
    _ -> copy_answer(machine, message)
  }
}

fn script_row_answer(
  machine: Machine,
  message: BackendMessage,
) -> Result(Transition, UnexpectedMessage) {
  case message {
    DataRow(values:) -> add_row(machine, values)
    CommandComplete(tag:) -> finish_statement(machine, tag)
    _ -> unexpected(machine, message)
  }
}

/// Takes the COPY of the copy step's direction, and refuses any other. To
/// refuse a `COPY ... FROM STDIN` the step sends CopyFail; for a copy in
/// both directions it sends CopyDone. The server ignores a Sync during a
/// copy, so in the extended protocol a new Sync follows.
fn copy_answer(
  machine: Machine,
  message: BackendMessage,
) -> Result(Transition, UnexpectedMessage) {
  case message {
    CopyInResponse(..) -> Ok(copy_in_started(machine))
    CopyOutResponse(..) -> Ok(copy_out_started(machine))
    CopyBothResponse(..) ->
      Ok(refuse_copy(machine, copy_done(), ReadingCopyOut))
    _ -> unexpected(machine, message)
  }
}

/// The copy step's `COPY ... FROM STDIN` reads data now, unless the app
/// abandoned it before it started: then it gets CopyFail and Sync at once.
fn copy_in_started(machine: Machine) -> Transition {
  let began = Machine(..machine, phase: CopyingIn, copy_began: True)
  case machine.copy_mode, machine.copy_abandoned {
    ExpectCopy(CopyFrom), False ->
      wait_with(Machine(..began, copy_signal: CopyBeganSignal))
    ExpectCopy(CopyFrom), True ->
      Continue(
        send: <<copy_abandonment():bits, sync():bits>>,
        machine: Machine(..began, copy_in_ended: True),
      )
    _, _ -> refuse_copy(machine, copy_refusal(), AwaitingCopyComplete)
  }
}

/// The rows of the copy step's `COPY ... TO STDOUT` follow now. The step
/// tells the start only when the app did not abandon the COPY before.
fn copy_out_started(machine: Machine) -> Transition {
  let signal = case machine.copy_abandoned {
    True -> NoCopySignal
    False -> CopyBeganSignal
  }
  case machine.copy_mode {
    ExpectCopy(CopyTo) ->
      Machine(
        ..machine,
        phase: ReadingCopyOut,
        copy_began: True,
        copy_signal: signal,
      )
      |> wait_with
    _ -> refuse_copy_out(machine)
  }
}

fn refuse_copy(machine: Machine, answer: BitArray, phase: Phase) -> Transition {
  let send = case machine.protocol {
    ExtendedProtocol -> <<answer:bits, sync():bits>>
    SimpleProtocol -> answer
  }
  Continue(send:, machine: Machine(..machine, phase:, copy_refused: True))
}

/// The server sends a `COPY ... TO STDOUT` to its end without an answer,
/// so the step only reads it.
fn refuse_copy_out(machine: Machine) -> Transition {
  wait_with(Machine(..machine, phase: ReadingCopyOut, copy_refused: True))
}

fn copy_out_answer(
  machine: Machine,
  message: BackendMessage,
) -> Result(Transition, UnexpectedMessage) {
  case message {
    CopyDataFromServer(data:) -> Ok(wait_with(copied_row(machine, data)))
    CopyDoneFromServer ->
      Ok(wait_with(Machine(..machine, phase: AwaitingCopyComplete)))
    _ -> unexpected(machine, message)
  }
}

/// A row of the copy step's own `COPY ... TO STDOUT` goes to the app,
/// unless the app abandoned the COPY. The rows of a refused COPY are
/// dropped.
fn copied_row(machine: Machine, row: BitArray) -> Machine {
  case machine.copy_began && !machine.copy_abandoned {
    True -> Machine(..machine, copy_signal: CopyRowSignal(row))
    False -> machine
  }
}

/// The CommandComplete that ends a COPY, with the row count of its tag.
fn copy_end_answer(
  machine: Machine,
  message: BackendMessage,
) -> Result(Transition, UnexpectedMessage) {
  let phase = case machine.protocol {
    ExtendedProtocol -> AwaitingReadyForQuery
    SimpleProtocol -> AwaitingStatementResult
  }
  case message {
    CommandComplete(tag:) ->
      complete_command(machine, tag)
      |> result.map(with_phase(_, phase))
      |> result.map(wait_with)
    _ -> unexpected(machine, message)
  }
}

fn ready_answer(
  machine: Machine,
  message: BackendMessage,
) -> Result(Transition, UnexpectedMessage) {
  case message {
    ReadyForQuery(status:) -> Ok(Ready(status:, machine:))
    _ -> unexpected(machine, message)
  }
}

fn with_phase(machine: Machine, phase: Phase) -> Machine {
  Machine(..machine, phase:)
}

fn advance(machine: Machine) -> Machine {
  case machine.next_phases {
    [phase, ..next_phases] -> Machine(..machine, phase:, next_phases:)
    [] -> Machine(..machine, phase: AwaitingReadyForQuery)
  }
}

fn wait_with(machine: Machine) -> Transition {
  Continue(send: <<>>, machine:)
}

fn unexpected(
  machine: Machine,
  message: BackendMessage,
) -> Result(value, UnexpectedMessage) {
  Error(UnexpectedMessage(
    message:,
    phase: machine.phase,
    asynchronous_messages: reverse(machine.messages),
  ))
}

fn with_columns(machine: Machine, columns: List(ResultColumn)) -> Machine {
  Machine(
    ..machine,
    columns: map(columns, column_description),
    cell_formats: ColumnFormats(map(columns, column_format)),
  )
}

fn column_description(column: ResultColumn) -> ColumnDescription {
  column.column
}

fn column_format(column: ResultColumn) -> Format {
  column.format
}

fn add_row(
  machine: Machine,
  values: List(Option(BitArray)),
) -> Result(Transition, UnexpectedMessage) {
  case row_cells(values, machine.cell_formats) {
    Ok(row) -> Ok(wait_with(Machine(..machine, rows: [row, ..machine.rows])))
    Error(Nil) -> unexpected(machine, DataRow(values:))
  }
}

/// Tags each value of a row with the format of its column. A row with
/// another number of values than the formats give is an error.
fn row_cells(
  values: List(Option(BitArray)),
  cell_formats: CellFormats,
) -> Result(List(Cell), Nil) {
  case cell_formats {
    BoundFormats([]) -> Ok(map(values, to_cell(_, TextFormat)))
    BoundFormats([format]) -> Ok(map(values, to_cell(_, format)))
    BoundFormats(formats) | ColumnFormats(formats) ->
      strict_zip(values, formats)
      |> result.map(map(_, paired_cell))
  }
}

fn paired_cell(value_and_format: #(Option(BitArray), Format)) -> Cell {
  to_cell(value_and_format.0, value_and_format.1)
}

fn to_cell(value: Option(BitArray), format: Format) -> Cell {
  case value, format {
    None, _ -> Null
    Some(bytes), BinaryFormat -> Binary(bytes)
    Some(bytes), TextFormat -> Text(bytes)
  }
}

/// Keeps the tag and its row count. A tag whose count is not a number is
/// an error.
fn complete_command(
  machine: Machine,
  tag: String,
) -> Result(Machine, UnexpectedMessage) {
  case row_count(tag) {
    Ok(count) -> Ok(Machine(..machine, tag:, count:))
    Error(Nil) -> unexpected(machine, CommandComplete(tag:))
  }
}

/// Ends one statement of a script: its result joins the others, and the
/// next statement starts with no columns and no rows.
fn finish_statement(
  machine: Machine,
  tag: String,
) -> Result(Transition, UnexpectedMessage) {
  use completed <- result.map(complete_command(machine, tag))
  let statement =
    StatementResult(
      columns: completed.columns,
      result: command_result(completed),
    )
  Machine(
    ..completed,
    phase: AwaitingStatementResult,
    results: [statement, ..completed.results],
    columns: [],
    cell_formats: ColumnFormats([]),
    rows: [],
  )
  |> wait_with
}

/// The row count of a command tag: its last number for the commands that
/// the docs list under "CommandComplete", else 0.
fn row_count(tag: String) -> Result(Int, Nil) {
  case split_once(tag, " ") {
    Ok(#(command, numbers)) -> counted_rows(command, numbers)
    Error(Nil) -> counted_rows(tag, "")
  }
}

fn counted_rows(command: String, numbers: String) -> Result(Int, Nil) {
  use <- guard(!contains(counted_commands, command), Ok(0))
  numbers
  |> split(" ")
  |> last
  |> result.try(parse)
}
