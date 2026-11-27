//// The query steps of the PostgreSQL wire protocol, as pure state machines:
//// prepare a statement, run a prepared statement, prepare and run in one
//// round trip, and run a script with the simple query protocol.
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

import dream_postgres/driver/encode.{copy_done, copy_refusal, sync}
import dream_postgres/driver/message.{
  type BackendMessage, type FrontendMessage, type ResultColumn, Bind,
  BindComplete, CommandComplete, CopyBothResponse, CopyDataFromServer,
  CopyDoneFromServer, CopyInResponse, CopyOutResponse, DataRow, Describe,
  EmptyQueryResponse, ErrorResponse, Execute, NoData, NoticeResponse,
  NotificationResponse, ParameterDescriptions, ParameterStatus, Parse,
  ParseComplete, Portal, Query, ReadyForQuery, RowDescription, Statement, Sync,
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

/// The message of the CopyFail that a step sends when the server asks for
/// the data of a `COPY ... FROM STDIN`.
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
  /// CopyData or CopyDone from the server, in a COPY that the step refused.
  ReadingCopyOut
  /// The CommandComplete or the ErrorResponse that ends a COPY that the
  /// step refused.
  AwaitingCopyComplete
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
  /// The server started a COPY, which a query step does not do. The step
  /// refused it and read up to ReadyForQuery. The error is the
  /// ErrorResponse that came after the COPY started, if one came: for a
  /// `COPY ... FROM STDIN` it is the server's answer to the CopyFail.
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
  let next_phases = [AwaitingParameterDescription, AwaitingStatementColumns]
  let machine =
    new_machine(
      ExtendedProtocol,
      AwaitingParseComplete,
      next_phases,
      BoundFormats([]),
    )
  Start(
    messages: [
      Parse(statement:, query:, parameter_type_ids:),
      Describe(Statement(statement)),
      Sync,
    ],
    state: PrepareState(machine),
  )
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
  Step(PrepareState, Outcome(StatementDescription, Failure)),
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
  let next_phases = [
    AwaitingBindComplete,
    AwaitingPortalColumns,
    ReadingExecuteRows,
  ]
  let machine =
    new_machine(
      ExtendedProtocol,
      AwaitingParseComplete,
      next_phases,
      BoundFormats(result_formats),
    )
  Start(
    messages: [
      Parse(statement: "", query:, parameter_type_ids:),
      Bind(portal: "", statement: "", parameters:, result_formats:),
      Describe(Portal("")),
      Execute(portal: "", row_limit: 0),
      Sync,
    ],
    state: PrepareAndRunState(machine),
  )
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
  let machine =
    new_machine(SimpleProtocol, AwaitingStatementResult, [], ColumnFormats([]))
  Start(messages: [Query(script)], state: SimpleQueryState(machine))
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

fn prepare_outcome(
  machine: Machine,
  status: TransactionStatus,
) -> Outcome(StatementDescription, Failure) {
  StatementDescription(parameters: machine.parameters, columns: machine.columns)
  |> step_result(machine, _)
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
    ReadingExecuteRows -> execute_answer(machine, message)
    AwaitingStatementResult -> statement_answer(machine, message)
    ReadingScriptRows -> script_row_answer(machine, message)
    ReadingCopyOut -> copy_out_answer(machine, message)
    AwaitingCopyComplete -> copy_end_answer(machine, message)
    AwaitingReadyForQuery | AwaitingReadyForQueryAfterError ->
      ready_answer(machine, message)
  }
}

fn keep(machine: Machine, message: AsynchronousMessage) -> Transition {
  wait_with(Machine(..machine, messages: [message, ..machine.messages]))
}

/// An ErrorResponse ends the work of the step: the server skips to the
/// Sync, or to the end of the Query, and sends ReadyForQuery.
fn server_error(
  machine: Machine,
  report: ServerReport,
) -> Result(Transition, UnexpectedMessage) {
  let ends_connection = contains(connection_ending_severities, report.severity)
  use <- guard(ends_connection, Ok(Ended(report:, machine:)))
  let after_error = machine.phase == AwaitingReadyForQueryAfterError
  use <- guard(after_error, unexpected(machine, ErrorResponse(report:)))
  Machine(
    ..machine,
    phase: AwaitingReadyForQueryAfterError,
    error: Some(report),
  )
  |> wait_with
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

/// Refuses a COPY. For a `COPY ... FROM STDIN` the step sends CopyFail;
/// for a copy in both directions it sends CopyDone. The server ignores a
/// Sync during a copy, so in the extended protocol a new Sync follows.
fn copy_answer(
  machine: Machine,
  message: BackendMessage,
) -> Result(Transition, UnexpectedMessage) {
  case message {
    CopyInResponse(..) ->
      Ok(refuse_copy(machine, copy_refusal(), AwaitingCopyComplete))
    CopyOutResponse(..) -> Ok(refuse_copy_out(machine))
    CopyBothResponse(..) ->
      Ok(refuse_copy(machine, copy_done(), ReadingCopyOut))
    _ -> unexpected(machine, message)
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
    CopyDataFromServer(..) -> Ok(wait_with(machine))
    CopyDoneFromServer ->
      Ok(wait_with(Machine(..machine, phase: AwaitingCopyComplete)))
    _ -> unexpected(machine, message)
  }
}

fn copy_end_answer(
  machine: Machine,
  message: BackendMessage,
) -> Result(Transition, UnexpectedMessage) {
  let phase = case machine.protocol {
    ExtendedProtocol -> AwaitingReadyForQuery
    SimpleProtocol -> AwaitingStatementResult
  }
  case message {
    CommandComplete(..) -> Ok(wait_with(Machine(..machine, phase:)))
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
