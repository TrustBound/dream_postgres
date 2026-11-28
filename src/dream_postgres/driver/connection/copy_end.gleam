//// The end of a COPY: the caller finishes it, abandons it, or ends.

import dream_postgres/driver/connection/copy_data.{read_on, take_row}
import dream_postgres/driver/connection/copy_exchange.{
  type CopyNotice, type CopySession, type EndedCopy, AbandonCopy, CallerLeft,
  CompleteCopy, CopySession, Finish, RowTaken,
}
import dream_postgres/driver/connection/copy_process.{running_copy}
import dream_postgres/driver/connection/running_request.{next_request, sent}
import dream_postgres/driver/connection/state.{
  type State, Open, RunningCopy, State,
}
import dream_postgres/driver/query/copy_step.{type CopyState} as query_copy_step
import dream_postgres/driver/transport
import gleam/erlang/process.{type Down}
import gleam/erlang/reference.{type Reference}
import gleam/option.{None, Some}

/// A notice of the caller of the COPY `id`.
pub fn copy_notice(state: State, id: Reference, notice: CopyNotice) -> State {
  case notice {
    RowTaken -> take_row(state, id)
    Finish(ending: CompleteCopy) ->
      finish_side(state, id, query_copy_step.finish_copy)
    Finish(ending: AbandonCopy) | CallerLeft ->
      finish_side(state, id, query_copy_step.abandon_copy)
  }
}

/// The caller ends its side of the COPY `id`. A COPY that runs ends with
/// the bytes that `ending` gives, and its end goes to the caller when the
/// server ended it. The end of a COPY that ended already is dropped, and
/// the process serves the next request. A COPY that is over changes
/// nothing.
fn finish_side(
  state: State,
  id: Reference,
  ending: fn(CopyState) -> #(CopyState, BitArray),
) -> State {
  case state.running, state.copy, state.link {
    Some(RunningCopy(state: copy_state, session:)), _, Open(socket:, ..)
      if session.id == id
    ->
      CopySession(..session, finished: True)
      |> stop_copy(state, socket, ending(copy_state), _)
    _, Some(ended), _ if ended.id == id -> drop_ended_copy(state, ended)
    _, _, _ -> state
  }
}

/// The caller of an ended COPY needs it no more: the process watches the
/// caller no more, and serves the next request.
fn drop_ended_copy(state: State, ended: EndedCopy) -> State {
  process.demonitor_process(ended.monitor)
  next_request(State(..state, copy: None))
}

/// Sends the bytes that end the COPY, stops waiting for the caller to take
/// a row, and reads on to the end of the COPY. The step drops the rows
/// after it.
fn stop_copy(
  state: State,
  socket: transport.Connection,
  stopped: #(CopyState, BitArray),
  session: CopySession,
) -> State {
  let #(copy_state, bytes) = stopped
  running_copy(state, copy_state, CopySession(..session, row_pushed: False))
  |> sent(socket, transport.send(socket, bytes))
  |> read_on
}

/// Ends the COPY that runs, if one runs, with the bytes that `ending`
/// gives.
pub fn end_running_copy(
  state: State,
  ending: fn(CopyState) -> #(CopyState, BitArray),
) -> State {
  case state.running, state.link {
    Some(RunningCopy(state: copy_state, session:)), Open(socket:, ..) ->
      stop_copy(state, socket, ending(copy_state), session)
    _, _ -> state
  }
}

/// The caller of a COPY ended: the COPY is abandoned, or its end is
/// dropped.
pub fn caller_down(state: State, down: Down) -> State {
  case state.running, state.copy, state.link {
    Some(RunningCopy(state: copy_state, session:)), _, Open(socket:, ..)
      if session.monitor == down.monitor
    ->
      CopySession(..session, finished: True)
      |> stop_copy(state, socket, query_copy_step.abandon_copy(copy_state), _)
    _, Some(ended), _ if ended.monitor == down.monitor ->
      drop_ended_copy(state, ended)
    _, _, _ -> state
  }
}
