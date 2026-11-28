//// The state machine that every step shares: its state, and the small moves
//// between the phases of a flow.

import dream_postgres/driver/encode.{sync}
import dream_postgres/driver/message.{type BackendMessage, ErrorResponse}
import dream_postgres/driver/query/step.{
  type AsynchronousMessage, type CopyDirection, type Failure, type Outcome,
  type Phase, type StatementResult, type UnexpectedMessage,
  AwaitingReadyForQuery, AwaitingReadyForQueryAfterError, CopyNotSupported,
  CopyingIn, Outcome, ServerError, UnexpectedMessage,
  connection_ending_severities,
}
import dream_postgres/internal/cell.{
  type Cell, type ColumnDescription, type CommandResult, type Format,
  type ParameterDescription, type ServerReport, type TransactionStatus,
  CommandResult,
}
import gleam/bool.{guard}
import gleam/list.{contains, reverse}
import gleam/option.{type Option, None, Some}

/// The state that every step shares. The lists that grow during the step
/// have their newest item first.
pub type Machine {
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
pub type Transition {
  Continue(send: BitArray, machine: Machine)
  Ready(status: TransactionStatus, machine: Machine)
  Ended(report: ServerReport, machine: Machine)
}

pub type QueryProtocol {
  ExtendedProtocol
  SimpleProtocol
}

/// The formats that tag the cells of each DataRow.
pub type CellFormats {
  /// The result formats of a Bind, by the rule of the protocol: none means
  /// text for each column, one means that format for each column, and more
  /// means one for each column.
  BoundFormats(List(Format))
  /// One format for each column, from a RowDescription.
  ColumnFormats(List(Format))
}

/// What a step does with a COPY that the server starts.
pub type CopyMode {
  /// A query step refuses every COPY.
  RefuseCopy
  /// The copy step takes a COPY of this direction, and refuses the others.
  ExpectCopy(direction: CopyDirection)
}

/// What the last message started in a copy step, for the step to tell.
pub type CopySignal {
  NoCopySignal
  CopyBeganSignal
  CopyRowSignal(row: BitArray)
}

pub fn new_machine(
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

pub fn keep(machine: Machine, message: AsynchronousMessage) -> Transition {
  wait_with(Machine(..machine, messages: [message, ..machine.messages]))
}

/// An ErrorResponse ends the work of the step: the server skips to the
/// Sync, or to the end of the Query, and sends ReadyForQuery. During a
/// `COPY ... FROM STDIN` the server read the Sync of the Execute already,
/// so the step sends a new one, unless it sent the one after its CopyDone
/// or CopyFail.
/// Whether the server still reads the CopyData of a `COPY ... FROM STDIN`.
pub fn copy_in_open(machine: Machine) -> Bool {
  machine.phase == CopyingIn && !machine.copy_in_ended
}

pub fn with_phase(machine: Machine, phase: Phase) -> Machine {
  Machine(..machine, phase:)
}

pub fn advance(machine: Machine) -> Machine {
  case machine.next_phases {
    [phase, ..next_phases] -> Machine(..machine, phase:, next_phases:)
    [] -> Machine(..machine, phase: AwaitingReadyForQuery)
  }
}

pub fn wait_with(machine: Machine) -> Transition {
  Continue(send: <<>>, machine:)
}

pub fn unexpected(
  machine: Machine,
  message: BackendMessage,
) -> Result(value, UnexpectedMessage) {
  Error(UnexpectedMessage(
    message:,
    phase: machine.phase,
    asynchronous_messages: reverse(machine.messages),
  ))
}

pub fn server_error(
  machine: Machine,
  report: ServerReport,
) -> Result(Transition, UnexpectedMessage) {
  let ends_connection = contains(connection_ending_severities, report.severity)
  use <- guard(ends_connection, Ok(Ended(report:, machine:)))
  let after_error = machine.phase == AwaitingReadyForQueryAfterError
  use <- guard(after_error, unexpected(machine, ErrorResponse(report:)))
  let send = case copy_in_open(machine) {
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

pub fn outcome(
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

pub fn step_result(machine: Machine, value: value) -> Result(value, Failure) {
  case machine.copy_refused, machine.error {
    True, error -> Error(CopyNotSupported(error:))
    False, Some(report) -> Error(ServerError(report:))
    False, None -> Ok(value)
  }
}

pub fn command_result(machine: Machine) -> CommandResult {
  CommandResult(
    rows: reverse(machine.rows),
    tag: machine.tag,
    count: machine.count,
  )
}
