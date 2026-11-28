//// The loop of the connection process: one message at a time, from callers,
//// timers and the socket.

import dream_postgres/driver/connection/copy_data.{chunk_received}
import dream_postgres/driver/connection/copy_end.{caller_down, copy_notice}
import dream_postgres/driver/connection/deadline_expiry.{
  cancel_finished, cancel_over, deadline_reached,
}
import dream_postgres/driver/connection/first_open.{
  attempt_first_open, open_first,
}
import dream_postgres/driver/connection/process_message.{
  type Message, type Request, type Snapshot, CallerDown, CancelFinished,
  CancelOver, CopyNotice, DeadlineReached, ExitSignal, OpenAttempt, OpenRequest,
  ReconnectNow, Request, SendChunk, Snapshot, SnapshotRequest, SocketMessage,
  StopRequest,
}
import dream_postgres/driver/connection/reconnect_attempt.{reconnect}
import dream_postgres/driver/connection/reply.{type ReplyTo, reply}
import dream_postgres/driver/connection/running_request.{accept_request}
import dream_postgres/driver/connection/socket_messages.{socket_message_received}
import dream_postgres/driver/connection/state.{
  type State, Lost, Open, State, Ticket,
}
import dream_postgres/driver/encode
import dream_postgres/driver/transaction.{
  aborting_error, transaction_status as tracked_status,
}
import dream_postgres/driver/transport
import gleam/erlang/process
import gleam/option.{type Option, None, Some}
import gleam/otp/actor

pub fn handle_message(
  state: State,
  message: Message,
) -> actor.Next(State, Message) {
  case message {
    Request(request:, deadline_milliseconds:) ->
      actor.continue(new_request(state, request, deadline_milliseconds))
    DeadlineReached(id:) -> actor.continue(deadline_reached(state, id))
    CancelFinished(id:, result: cancel_result) ->
      actor.continue(cancel_finished(state, id, cancel_result))
    CancelOver(id:) -> actor.continue(cancel_over(state, id))
    SnapshotRequest(reply_to) -> {
      reply(reply_to, snapshot_of(state))
      actor.continue(state)
    }
    StopRequest(reply_to) -> stop_process(state, Some(reply_to))
    ExitSignal(_exit) -> stop_process(state, None)
    SocketMessage(socket_message) ->
      actor.continue(socket_message_received(state, socket_message))
    ReconnectNow(attempt:, previous_wait_milliseconds:) ->
      actor.continue(reconnect(state, attempt, previous_wait_milliseconds))
    SendChunk(id:, chunk:, reply: reply_to) ->
      actor.continue(chunk_received(state, id, chunk, reply_to))
    CopyNotice(id:, notice:) -> actor.continue(copy_notice(state, id, notice))
    CallerDown(down:) -> actor.continue(caller_down(state, down))
    OpenRequest(reply_to) -> open_first(state, reply_to)
    OpenAttempt(attempt:, previous_wait_milliseconds:) ->
      actor.continue(attempt_first_open(
        state,
        attempt,
        previous_wait_milliseconds,
      ))
  }
}

fn snapshot_of(state: State) -> Snapshot {
  Snapshot(
    transaction_status: tracked_status(state.tracker),
    aborted_by: aborting_error(state.tracker),
    parameters: state.parameters,
  )
}

/// Stops the process. A connected socket gets a Terminate first, so the
/// server ends the session cleanly.
fn stop_process(
  state: State,
  reply_to: Option(ReplyTo(Nil)),
) -> actor.Next(State, Message) {
  case state.link {
    Open(socket:, ..) -> terminate(socket)
    Lost(..) -> Nil
  }
  option.map(reply_to, reply(_, Nil))
  actor.stop()
}

/// Sends Terminate and closes the socket. A socket that cannot take the
/// Terminate is broken already, so closing it is all that is left to do.
fn terminate(socket: transport.Connection) -> Nil {
  case transport.send(socket, encode.terminate()) {
    Ok(Nil) | Error(_broken) -> transport.close(socket)
  }
}

/// Gives the request its number and starts its deadline timer.
fn new_request(state: State, request: Request, deadline: Int) -> State {
  let id = state.next_id
  let timer = process.send_after(state.subject, deadline, DeadlineReached(id))
  accept_request(State(..state, next_id: id + 1), Ticket(id:, request:, timer:))
}
