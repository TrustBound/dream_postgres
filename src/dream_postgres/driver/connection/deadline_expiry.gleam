//// The deadline of a request passed: the cancel, and the end of the cancel.

import dream_postgres/driver/connection/cancel.{
  for_current, lose_at_deadline, start_cancel,
}
import dream_postgres/driver/connection/copy_end.{end_running_copy}
import dream_postgres/driver/connection/process_message.{type CancelFailure}
import dream_postgres/driver/connection/request_deadline.{end_waiting}
import dream_postgres/driver/connection/running_request.{next_request}
import dream_postgres/driver/connection/state.{
  type Current, type State, Current, Open, State,
}
import dream_postgres/driver/query/copy_step as query_copy_step
import dream_postgres/driver/transport
import gleam/option.{Some}

/// The deadline of a waiting request ends it at once. The deadline of the
/// running request sends a cancel on a new socket, with the TLS settings
/// of the connection. A session with no cancel key cannot cancel, so its
/// connection is closed and replaced.
///
/// A COPY that runs takes no more chunks. A `COPY ... FROM STDIN` gets
/// both the cancel and, once the cancel is done, a CopyFail, because each
/// covers a case that the other does not: the cancel stops a server that
/// is busy with rows it received already (triggers, indexes, constraint
/// checks), and the CopyFail ends a COPY whose server waits for data,
/// where it does not act on a cancel. The rest of a
/// `COPY ... TO STDOUT` is read and dropped at once, because the server
/// acts on a cancel only between rows, never while it waits to write a row
/// that the caller did not take. A COPY that the server ended already
/// waits for its caller, with its own result.
pub fn deadline_reached(state: State, id: Int) -> State {
  case state.current, state.running, state.link {
    Some(current), Some(_running), Open(socket:, ..) if current.id == id ->
      start_cancel(state, socket, current)
      |> end_running_copy(query_copy_step.stop_at_deadline)
    _, _, _ -> end_waiting(state, id)
  }
}

/// A cancel that the server took lets the request end. A cancel that could
/// not reach the server leaves the statement running, so the connection
/// is closed and replaced.
pub fn cancel_finished(
  state: State,
  id: Int,
  cancel_result: Result(Nil, CancelFailure),
) -> State {
  case cancel_result {
    Ok(Nil) -> for_current(state, id, mark_cancel_done)
    Error(_unreached) -> for_current(state, id, lose_at_deadline)
  }
}

/// A cancel that did not end in time leaves the connection in an unknown
/// state, so it is closed and replaced.
pub fn cancel_over(state: State, id: Int) -> State {
  for_current(state, id, lose_at_deadline)
}

/// A `COPY ... FROM STDIN` that still runs gets its CopyFail only now.
/// The server ignores a cancel while it waits for CopyData, and it drops
/// a pending cancel when a statement fails. A CopyFail sent before the
/// server took the cancel could end the COPY first, and leave the cancel
/// to stop the next statement.
fn mark_cancel_done(
  state: State,
  _socket: transport.Connection,
  current: Current,
) -> State {
  State(..state, current: Some(Current(..current, cancel_done: True)))
  |> end_running_copy(query_copy_step.abandon_copy)
  |> next_request
}
