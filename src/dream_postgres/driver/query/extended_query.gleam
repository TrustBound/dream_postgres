//// The Extended Query protocol: Parse and Describe to prepare a statement, Bind
//// and Execute to run it, and both in one round trip.

import dream_postgres/driver/cell.{
  type Cell, type CommandResult, type Format, type ServerReport,
  type StatementDescription, type TransactionStatus, StatementDescription,
}
import dream_postgres/driver/housekeeping_sql.{type HousekeepingSql}
import dream_postgres/driver/message.{
  type BackendMessage, type FrontendMessage, Bind, Close, Describe, Execute,
  Parse, Portal, Statement, Sync,
}
import dream_postgres/driver/query/machine.{
  type Machine, type Transition, BoundFormats, Continue, Ended, ExtendedProtocol,
  Ready, command_result, new_machine, outcome, step_result,
}
import dream_postgres/driver/query/receive.{receive}
import dream_postgres/driver/query/step.{
  type Failure, type HousekeepingStart, type Outcome, type Phase, type Start,
  type StatementResult, type Step, type UnexpectedMessage, AwaitingBindComplete,
  AwaitingCloseComplete, AwaitingParameterDescription, AwaitingParseComplete,
  AwaitingPortalColumns, AwaitingStatementColumns, ConnectionEnded, Finished,
  HousekeepingStart, ReadingExecuteRows, Send, Start, StatementResult, Wait,
}
import gleam/list.{map, reverse}
import gleam/option.{None, Some}
import gleam/result

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

pub fn to_step(
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
