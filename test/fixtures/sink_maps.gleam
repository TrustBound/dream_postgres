//// The map functions of the sink tests: conversions from the driver's
//// event types to the messages of the test process, and maps that crash.

import dream_postgres/driver/cell.{type ServerReport}
import dream_postgres/driver/connection/outcome.{type Notification}
import dream_postgres/driver/listener/process_message.{
  type ListenerMessage, ListenFailed, Listening, NotListening,
  NotificationArrived,
}
import gleam/erlang/process.{type Subject}

/// An event of the driver, wrapped in a message type of the test.
pub type Wrapped(event) {
  Wrapped(event: event)
}

/// Converts a notice to its SQLSTATE code.
pub fn report_code(report: ServerReport) -> String {
  report.code
}

/// Converts a notification to its payload.
pub fn notification_payload(notification: Notification) -> String {
  notification.payload
}

/// Converts a listener message to a text: the payload of a notification,
/// or the name of any other message.
pub fn listener_message_text(message: ListenerMessage) -> String {
  case message {
    NotificationArrived(notification:) -> notification.payload
    NotListening -> "NotListening"
    Listening(channel: _) -> "Listening"
    ListenFailed(channel: _, error: _) -> "ListenFailed"
  }
}

/// Raises an Erlang error with the reason, for a map that crashes.
@external(erlang, "erlang", "error")
fn raise_error(reason: String) -> message

/// A map that crashes on each event.
pub fn crash(_event: event) -> message {
  raise_error("the map of the test crashed")
}

/// A map that sends each event to `witness`, then crashes. The witness
/// shows how many times the driver called the map.
pub fn crash_after_telling(witness: Subject(event)) -> fn(event) -> message {
  fn(event) {
    process.send(witness, event)
    raise_error("the map of the test crashed")
  }
}
