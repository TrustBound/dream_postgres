//// The COPY protocol: CopyIn and CopyOut, the CopyData that the app sends, and
//// the end of the COPY.

import dream_postgres/driver/encode.{
  copy_abandonment, copy_data_messages, copy_done, sync,
}
import dream_postgres/driver/message.{
  type BackendMessage, Bind, Execute, Parse, Sync,
}
import dream_postgres/driver/query/machine.{
  type Machine, type Transition, BoundFormats, Continue, CopyBeganSignal,
  CopyRowSignal, Ended, ExpectCopy, ExtendedProtocol, Machine, NoCopySignal,
  Ready, command_result, copy_in_open, new_machine, outcome, step_result,
}
import dream_postgres/driver/query/receive.{receive}
import dream_postgres/driver/query/step.{
  type AsynchronousMessage, type CopyDirection, type CopyResult, type Failure,
  type Outcome, type Start, type UnexpectedMessage, AwaitingBindComplete,
  AwaitingParseComplete, CopyCompleted, CopyTo, NoCopyStarted,
  ReadingExecuteRows, Start,
}
import dream_postgres/internal/cell.{type ServerReport, type TransactionStatus}
import gleam/list.{reverse}
import gleam/option.{None}
import gleam/result

/// The state of a copy step.
pub opaque type CopyState {
  CopyState(machine: Machine)
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

/// Starts a copy step: Parse, Bind and Execute of one statement on the
/// unnamed statement and portal, and Sync. The extended protocol takes one
/// statement only, so a simple query cannot hide a second one. The server reads
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
  copy_in_open(state.machine)
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
