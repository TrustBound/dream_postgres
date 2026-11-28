//// A message of the server while no request runs: a parameter change, a notice,
//// or a notification is kept, and any other message ends the connection.

import dream_postgres/driver/connection/event.{
  ProtocolViolation, ServerEndedConnection,
}
import dream_postgres/driver/connection/notices.{keep_asynchronous}
import dream_postgres/driver/connection/outcome.{UnexpectedIdleMessage}
import dream_postgres/driver/connection/reconnection.{lose}
import dream_postgres/driver/connection/state.{type State, State}
import dream_postgres/driver/message.{
  type BackendMessage, ErrorResponse, NoticeResponse, NotificationResponse,
  ParameterStatus,
}
import dream_postgres/driver/query/step.{Notice} as query_step
import dream_postgres/driver/transport
import gleam/dict

/// A message between requests: a parameter change, a notice, a
/// notification, or the error that ends the session.
pub fn idle_message(
  state: State,
  socket: transport.Connection,
  message: BackendMessage,
) -> State {
  case message {
    ParameterStatus(name:, value:) ->
      State(..state, parameters: dict.insert(state.parameters, name, value))
    NoticeResponse(report) -> keep_asynchronous(state, Notice(report))
    NotificationResponse(process_id:, channel:, payload:) ->
      keep_asynchronous(
        state,
        query_step.Notification(process_id, channel, payload),
      )
    ErrorResponse(report) -> lose(state, socket, ServerEndedConnection(report))
    _other ->
      lose(state, socket, ProtocolViolation(UnexpectedIdleMessage(message)))
  }
}
