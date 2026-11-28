//// The answers of the server in a COPY flow: CopyInResponse, CopyOutResponse,
//// CopyData, and CopyDone.

import dream_postgres/driver/encode.{
  copy_abandonment, copy_done, copy_refusal, sync,
}
import dream_postgres/driver/message.{
  type BackendMessage, CommandComplete, CopyBothResponse, CopyDataFromServer,
  CopyDoneFromServer, CopyInResponse, CopyOutResponse,
}
import dream_postgres/driver/query/machine.{
  type Machine, type Transition, Continue, CopyBeganSignal, CopyRowSignal,
  ExpectCopy, ExtendedProtocol, Machine, NoCopySignal, SimpleProtocol,
  unexpected, wait_with, with_phase,
}
import dream_postgres/driver/query/result_rows.{complete_command}
import dream_postgres/driver/query/step.{
  type Phase, type UnexpectedMessage, AwaitingCopyComplete,
  AwaitingReadyForQuery, AwaitingStatementResult, CopyFrom, CopyTo, CopyingIn,
  ReadingCopyOut,
}
import gleam/result

/// Takes the COPY of the copy step's direction, and refuses any other. To
/// refuse a `COPY ... FROM STDIN` the step sends CopyFail; for a copy in
/// both directions it sends CopyDone. The server ignores a Sync during a
/// copy, so in the extended protocol a new Sync follows.
pub fn copy_answer(
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

pub fn copy_out_answer(
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
pub fn copy_end_answer(
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
