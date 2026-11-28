//// The first connect and login of a connection process, and its retries.

import dream_postgres/driver/connection/backoff.{backoff_wait}
import dream_postgres/driver/connection/event.{
  type ConnectError, ConnectFailed, Connected,
}
import dream_postgres/driver/connection/process_message.{
  type Message, OpenAttempt,
}
import dream_postgres/driver/connection/reconnection.{tell}
import dream_postgres/driver/connection/reply.{type ReplyTo, reply}
import dream_postgres/driver/connection/request_failure.{RefusedNotConnected}
import dream_postgres/driver/connection/running_request.{read_messages}
import dream_postgres/driver/connection/session_state.{connected_state}
import dream_postgres/driver/connection/startup.{open_session}
import dream_postgres/driver/connection/state.{type State, Lost, State}
import gleam/erlang/process
import gleam/otp/actor

/// A first open of a supervised process. A failed one leaves the process
/// up, refusing requests as not connected, and tries again after the
/// reconnect backoff.
pub fn attempt_first_open(
  state: State,
  attempt: Int,
  previous_wait_milliseconds: Int,
) -> State {
  case open_session(state.config) {
    Ok(session) ->
      connected_state(state, session) |> tell(Connected) |> read_messages
    Error(error) -> {
      let state = tell(state, ConnectFailed(error))
      let wait =
        backoff_wait(
          state.config.reconnect,
          attempt,
          previous_wait_milliseconds,
        )
      process.send_after(state.subject, wait, OpenAttempt(attempt + 1, wait))
      State(..state, link: Lost(RefusedNotConnected(error)))
    }
  }
}

/// The first open of the process. A process that cannot connect answers
/// with the error and stops.
pub fn open_first(
  state: State,
  reply_to: ReplyTo(Result(Nil, ConnectError)),
) -> actor.Next(State, Message) {
  case open_session(state.config) {
    Ok(session) -> {
      let state = connected_state(state, session) |> tell(Connected)
      reply(reply_to, Ok(Nil))
      actor.continue(read_messages(state))
    }
    Error(error) -> {
      reply(reply_to, Error(error))
      actor.stop()
    }
  }
}
