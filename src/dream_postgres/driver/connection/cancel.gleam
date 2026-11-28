//// The CancelRequest of a request that passed its deadline.

import dream_postgres/driver/connection/event.{
  ClosedAfterDeadline, ConnectionLost,
}
import dream_postgres/driver/connection/process_message.{
  type CancelFailure, type Message, CancelFinished, CancelNotAnswered,
  CancelNotSent, CancelOver, CancelUnencodable, CancelUnreachable,
}
import dream_postgres/driver/connection/reconnection.{end_link}
import dream_postgres/driver/connection/request_failure.{DeadlinePassed}
import dream_postgres/driver/connection/settings.{type ConnectionConfig}
import dream_postgres/driver/connection/state.{
  type Current, type State, Current, Open, State,
}
import dream_postgres/driver/deadline
import dream_postgres/driver/encode.{encode}
import dream_postgres/driver/login.{type CancelKey}
import dream_postgres/driver/message.{
  type BackendMessage, CancelRequest, ErrorResponse,
}
import dream_postgres/driver/transport.{ReceiveFailed, SocketClosed}
import gleam/erlang/process.{type Subject}
import gleam/option.{None, Some}
import gleam/result.{map_error, try}

/// Acts on the request `id` while it is the current one of a connected
/// session. A message about a request that ended already changes nothing.
pub fn for_current(
  state: State,
  id: Int,
  action: fn(State, transport.Connection, Current) -> State,
) -> State {
  case state.current, state.link {
    Some(current), Open(socket:, ..) if current.id == id ->
      action(state, socket, current)
    _, _ -> state
  }
}

/// The request whose deadline passed fails with `DeadlinePassed`. The
/// others fail because the process closed the connection after it.
pub fn lose_at_deadline(
  state: State,
  socket: transport.Connection,
  _current: Current,
) -> State {
  end_link(
    state,
    socket,
    running_error: DeadlinePassed(cancelled: False),
    end: ConnectionLost(ClosedAfterDeadline),
  )
}

/// Opens a new connection with the same settings, sends the CancelRequest,
/// and waits until the server closes it, which it does after the cancel.
/// It runs in its own process, so the connection process goes on reading.
fn cancel(
  config: ConnectionConfig,
  key: CancelKey,
  owner: Subject(Message),
  id: Int,
) -> Nil {
  process.send(owner, CancelFinished(id, send_cancel(config, key)))
}

fn send_cancel(
  config: ConnectionConfig,
  key: CancelKey,
) -> Result(Nil, CancelFailure) {
  use request <- try(
    encode(CancelRequest(key.process_id, key.secret_key))
    |> map_error(CancelUnencodable),
  )
  // The cancel process ends within half the cancel timeout: its connect
  // and its wait for the server to close the cancel connection, which the
  // server does once it took the cancel, share that one deadline. So a
  // cancel that never gets an answer fails before the timeout of the
  // request.
  let cancel_deadline =
    deadline.from_now(config.cancel_timeout_milliseconds / 2)
  use socket <- try(
    transport.connect(config.transport, cancel_deadline)
    |> map_error(CancelUnreachable),
  )
  let sent = transport.send(socket, request)
  let closed = transport.receive(socket, deadline.time_left(cancel_deadline))
  transport.close(socket)
  use Nil <- try(sent |> map_error(CancelNotSent))
  case closed {
    Ok(_bytes) | Error(ReceiveFailed(SocketClosed)) -> Ok(Nil)
    Error(error) -> Error(CancelNotAnswered(error))
  }
}

pub fn start_cancel(
  state: State,
  socket: transport.Connection,
  current: Current,
) -> State {
  let state =
    State(..state, current: Some(Current(..current, deadline_passed: True)))
  case state.cancel_key {
    Some(key) -> {
      process.spawn_unlinked(fn() {
        cancel(state.config, key, state.subject, current.id)
      })
      let delay = state.config.cancel_timeout_milliseconds
      process.send_after(state.subject, delay, CancelOver(current.id))
      state
    }
    None -> lose_at_deadline(state, socket, current)
  }
}

/// The server confirms a cancel with the error 57014.
pub fn confirm_cancel(state: State, message: BackendMessage) -> State {
  case message, state.current {
    ErrorResponse(report), Some(current) if current.deadline_passed ->
      State(
        ..state,
        current: Some(
          Current(..current, cancel_confirmed: report.code == "57014"),
        ),
      )
    _, _ -> state
  }
}
