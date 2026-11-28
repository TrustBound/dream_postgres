//// Losing the connection, and connecting again after a backoff.

import dream_postgres/driver/connection/backoff.{backoff_wait}
import dream_postgres/driver/connection/copy_process.{lost_copy}
import dream_postgres/driver/connection/event.{
  type ConnectionEnd, type ConnectionEvent, type LossReason, Disconnected,
  ServerStoppedReading, SocketFailed,
}
import dream_postgres/driver/connection/process_message.{ReconnectNow}
import dream_postgres/driver/connection/refusal.{refuse_running, refuse_ticket}
import dream_postgres/driver/connection/request_deadline.{end_current}
import dream_postgres/driver/connection/request_failure.{
  type RequestFailure, ConnectionEnded, RefusedWithFailure,
}
import dream_postgres/driver/connection/settings.{ConnectionConfig}
import dream_postgres/driver/connection/state.{type State, Lost, Open, State}
import dream_postgres/driver/sink.{type Delivery, Delivered, MapFailed}
import dream_postgres/driver/transaction.{new_tracker}
import dream_postgres/driver/transport.{type SendError, SendFailed, SendTimedOut}
import gleam/erlang/process
import gleam/list.{reverse}
import gleam/option.{None, Some}

/// The connection is lost: the socket closes, the running request and
/// every waiting one fail with the error, the subscriber hears of it, and
/// a reconnect follows after the first delay of the backoff.
pub fn lose(
  state: State,
  socket: transport.Connection,
  end: ConnectionEnd,
) -> State {
  end_link(state, socket, running_error: ConnectionEnded(end), end:)
}

/// Ends the link. The running request, and a COPY that runs, fail with
/// `running_error`. The waiting requests and the requests that come while
/// the link is lost get `ConnectionEnded(end)`, and the subscriber gets
/// `Disconnected(end)`.
pub fn end_link(
  state: State,
  socket: transport.Connection,
  running_error running_error: RequestFailure,
  end end: ConnectionEnd,
) -> State {
  let refusal = RefusedWithFailure(ConnectionEnded(end))
  transport.close(socket)
  option.map(state.running, refuse_running(_, running_error))
  list.each(reverse(state.waiting), refuse_ticket(_, refusal))
  let state = tell(state, Disconnected(end))
  schedule_reconnect(state, 0, 0)
  State(
    ..end_current(state),
    link: Lost(refusal),
    running: None,
    waiting: [],
    tracker: new_tracker(),
    copy: lost_copy(state, running_error),
  )
}

/// Sends the event through the events sink, if the process has one.
pub fn tell(state: State, event: ConnectionEvent) -> State {
  case state.config.events {
    Some(events) -> sink.deliver(events, event) |> keep_events(state, _)
    None -> state
  }
}

/// An events sink whose map crashed is dropped.
fn keep_events(state: State, delivery: Delivery) -> State {
  case delivery {
    Delivered -> state
    MapFailed ->
      State(..state, config: ConnectionConfig(..state.config, events: None))
  }
}

pub fn schedule_reconnect(
  state: State,
  attempt: Int,
  previous_wait_milliseconds: Int,
) -> Nil {
  let wait =
    backoff_wait(state.config.reconnect, attempt, previous_wait_milliseconds)
  process.send_after(state.subject, wait, ReconnectNow(attempt, wait))
  Nil
}

pub fn lose_if_connected(
  state: State,
  socket: transport.Connection,
  end: ConnectionEnd,
) -> State {
  case state.link {
    Open(..) -> lose(state, socket, end)
    Lost(..) -> state
  }
}

pub fn send_loss(error: SendError) -> LossReason {
  case error {
    SendTimedOut -> ServerStoppedReading
    SendFailed(error) -> SocketFailed(error)
  }
}
