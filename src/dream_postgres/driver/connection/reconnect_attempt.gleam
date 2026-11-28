//// An attempt to connect again: it opens the socket, logs in, and goes on to
//// the waiting requests.

import dream_postgres/driver/connection/event.{ReconnectFailed, Reconnected}
import dream_postgres/driver/connection/reconnection.{schedule_reconnect, tell}
import dream_postgres/driver/connection/running_request.{read_messages}
import dream_postgres/driver/connection/session_state.{connected_state}
import dream_postgres/driver/connection/startup.{open_session}
import dream_postgres/driver/connection/state.{type State}

/// Each `ReconnectNow` comes from one loss or one failed attempt, while
/// the link is lost, so the process connects only when it has no socket.
pub fn reconnect(
  state: State,
  attempt: Int,
  previous_wait_milliseconds: Int,
) -> State {
  case open_session(state.config) {
    Ok(session) ->
      tell(state, Reconnected) |> connected_state(session) |> read_messages
    Error(connect_error) -> {
      let state = tell(state, ReconnectFailed(connect_error))
      schedule_reconnect(state, attempt + 1, previous_wait_milliseconds)
      state
    }
  }
}
