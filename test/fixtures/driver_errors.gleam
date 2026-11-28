//// Request failures of a driver connection that need more than one
//// constructor, for the tests of the client reason of each driver error.

import dream_postgres/driver/connection/event as connection_event
import dream_postgres/driver/connection/outcome as connection_outcome
import dream_postgres/driver/connection/request_failure.{type RequestFailure} as connection_request_failure
import dream_postgres/driver/message.{type BackendMessage, type ProtocolError}
import dream_postgres/driver/query/step.{type Phase} as query_step

/// A message from the server that the driver cannot decode.
///
/// ## Example
///
/// ```gleam
/// driver_errors.undecodable_message(message.UnknownMessageType(33))
/// ```
pub fn undecodable_message(protocol_error: ProtocolError) -> RequestFailure {
  connection_request_failure.ConnectionEnded(
    connection_event.ProtocolViolation(connection_outcome.UndecodableMessage(
      protocol_error,
    )),
  )
}

/// A message from the server that comes while the driver reads the rows of
/// an Execute.
///
/// ## Example
///
/// ```gleam
/// driver_errors.unexpected_message(message.BindComplete)
/// ```
pub fn unexpected_message(backend_message: BackendMessage) -> RequestFailure {
  unexpected(backend_message, query_step.ReadingExecuteRows)
}

/// A NoData message from the server that comes in the phase `phase` of a
/// query.
///
/// ## Example
///
/// ```gleam
/// driver_errors.unexpected_message_in_phase(query_step.AwaitingBindComplete)
/// ```
pub fn unexpected_message_in_phase(phase: Phase) -> RequestFailure {
  unexpected(message.NoData, phase)
}

fn unexpected(backend_message: BackendMessage, phase: Phase) -> RequestFailure {
  connection_request_failure.ConnectionEnded(
    connection_event.ProtocolViolation(
      connection_outcome.UnexpectedServerMessage(
        query_step.UnexpectedMessage(
          message: backend_message,
          phase:,
          asynchronous_messages: [],
        ),
      ),
    ),
  )
}
