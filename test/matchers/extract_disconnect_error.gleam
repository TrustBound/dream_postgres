//// Extracts the error of a disconnect event of the connection process.

import dream_postgres/driver/connection.{
  type ConnectionEvent, type RequestFailure, Disconnected,
}
import dream_test/types.{
  type MatchResult, AssertionFailure, CustomMatcherFailure, MatchFailed, MatchOk,
}
import gleam/option.{Some}
import gleam/string.{inspect}

/// Gives the error of a `Disconnected` event. Fails for other events.
///
/// ```gleam
/// next_event(events)
/// |> should
/// |> be_ok
/// |> extract_disconnect_error
/// |> be_equal(ConnectionLost(SocketFailed(SocketClosed)))
/// |> or_fail_with("Expected the loss of the socket")
/// ```
pub fn extract_disconnect_error(
  result: MatchResult(ConnectionEvent),
) -> MatchResult(RequestFailure) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(event) -> error_of(event)
  }
}

fn error_of(event: ConnectionEvent) -> MatchResult(RequestFailure) {
  case event {
    Disconnected(error) -> MatchOk(error)
    _other ->
      MatchFailed(AssertionFailure(
        operator: "extract_disconnect_error",
        message: "",
        payload: Some(CustomMatcherFailure(
          actual: inspect(event),
          description: "Expected a Disconnected event",
        )),
      ))
  }
}
