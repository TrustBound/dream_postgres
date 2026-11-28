//// A COPY in the process: the rows that it pushes to the caller and the end
//// that it settles.

import dream_postgres/driver/connection/copy_exchange.{
  type CopyFault, type CopySession, type EndedCopy, CopyFaultFailed,
  CopyFaultNotStarted, CopyFaultRefused, CopySession, EndedCopy, PushedEnd,
  PushedRow, StartEnded,
}
import dream_postgres/driver/connection/notices.{take_pending}
import dream_postgres/driver/connection/outcome.{Outcome}
import dream_postgres/driver/connection/reply.{type ReplyTo, reply}
import dream_postgres/driver/connection/request_failure.{
  type ChunkError, type RequestFailure, ChunkCopyNotRunning, ChunkFailed,
  ChunkRefused, DeadlinePassed,
}
import dream_postgres/driver/connection/state.{
  type State, Current, RunningCopy, State,
}
import dream_postgres/driver/query/copy_step.{type CopyState}
import dream_postgres/driver/query/step.{
  type CopyResult, type Failure, CopyCompleted, CopyNotSupported, NoCopyStarted,
  ServerError,
} as query_step
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result.{map_error}

pub fn running_copy(
  state: State,
  copy_state: CopyState,
  session: CopySession,
) -> State {
  State(..state, running: Some(RunningCopy(copy_state, session)))
}

/// A row goes to the caller. The process reads nothing more from the
/// socket until the caller took it.
pub fn copy_row(
  state: State,
  copy_state: CopyState,
  session: CopySession,
  row: BitArray,
) -> State {
  reply(session.pushes, PushedRow(row))
  running_copy(state, copy_state, CopySession(..session, row_pushed: True))
}

/// The row count of the COPY, or why there is none. A statement that ran
/// in place of the COPY gives its outcome, with the pending notices and
/// notifications.
pub fn copy_result(
  state: State,
  outcome: query_step.Outcome(CopyResult, Failure),
) -> #(State, Result(Int, CopyFault)) {
  case outcome.result {
    Ok(CopyCompleted(count:)) -> #(state, Ok(count))
    Ok(NoCopyStarted(result:)) -> {
      let #(state, completed) =
        take_pending(state, Outcome([], result, [], [], outcome.status))
      #(state, Error(CopyFaultNotStarted(Some(completed))))
    }
    Error(CopyNotSupported(..)) -> #(state, Error(CopyFaultNotStarted(None)))
    Error(ServerError(report)) -> #(
      state,
      Error(CopyFaultRefused(report, outcome.status)),
    )
  }
}

pub fn deadline_result(
  state: State,
  ended: Result(Int, CopyFault),
) -> Result(Int, CopyFault) {
  case state.current {
    Some(Current(deadline_passed: True, cancel_confirmed:, ..)) ->
      Error(CopyFaultFailed(DeadlinePassed(cancelled: cancel_confirmed)))
    _ -> ended
  }
}

/// Gives the end of the COPY to its caller, and keeps the end while the
/// caller did not finish its side yet.
pub fn settle_copy(
  session: CopySession,
  ended: Result(Int, CopyFault),
  warning_code: Option(String),
) -> Option(EndedCopy) {
  answer_session(session, ended, warning_code)
  close_session(session, ended)
}

/// Gives the end of the COPY to each chunk that waits for it, and to the
/// caller: to its start, when it still waits for the start, else as a
/// push.
pub fn answer_session(
  session: CopySession,
  ended: Result(Int, CopyFault),
  warning_code: Option(String),
) -> Nil {
  list.each(session.waiting_chunks, reply(_, chunk_answer(ended)))
  case session.start {
    Some(start) ->
      reply(start, result.replace(ended, Nil) |> map_error(StartEnded))
    None -> reply(session.pushes, PushedEnd(ended, warning_code))
  }
}

/// A caller that got the end with its start, or that finished its side
/// already, needs the COPY no more, and the process watches it no more.
/// Else the end waits until the caller finishes its side.
fn close_session(
  session: CopySession,
  ended: Result(Int, CopyFault),
) -> Option(EndedCopy) {
  case session.start, session.finished {
    None, False -> Some(EndedCopy(session.id, session.monitor, ended))
    Some(_start), _ | None, True -> {
      process.demonitor_process(session.monitor)
      None
    }
  }
}

/// A chunk that met the end of its COPY: the failure or the refusal that
/// ended it. A COPY that ended with no failure takes no more data.
pub fn chunk_answer(ended: Result(Int, CopyFault)) -> Result(Nil, ChunkError) {
  case ended {
    Error(CopyFaultFailed(failure)) -> Error(ChunkFailed(failure))
    Error(CopyFaultRefused(report, status)) ->
      Error(ChunkRefused(report, status))
    Ok(_count) | Error(CopyFaultNotStarted(..)) -> Error(ChunkCopyNotRunning)
  }
}

/// A chunk for a COPY that does not run, and that did not end with a
/// failure that the process keeps: it gets `ChunkCopyNotRunning`.
pub fn refuse_chunk(reply_to: ReplyTo(Result(Nil, ChunkError))) -> Nil {
  reply(reply_to, Error(ChunkCopyNotRunning))
}

/// The process pushed a row that the caller did not take yet, so it reads
/// nothing more from the socket.
pub fn paused(state: State) -> Bool {
  case state.running {
    Some(RunningCopy(session: CopySession(row_pushed: True, ..), ..)) -> True
    _ -> False
  }
}

/// A COPY that runs when the connection is lost ends with the loss. One
/// that ended before keeps its own result.
pub fn lost_copy(state: State, failure: RequestFailure) -> Option(EndedCopy) {
  case state.running {
    Some(RunningCopy(session:, ..)) ->
      close_session(session, Error(CopyFaultFailed(failure)))
    _ -> state.copy
  }
}
