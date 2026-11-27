//// Extracts the error of a failed reconnect event of the connection process.

import dream_postgres/driver/connection.{
  type ConnectError, type ConnectionEvent, ReconnectFailed,
}
import dream_test/types.{
  type MatchResult, AssertionFailure, CustomMatcherFailure, MatchFailed, MatchOk,
}
import gleam/option.{Some}
import gleam/string.{inspect}

/// Gives the error of a `ReconnectFailed` event. Fails for other events.
///
/// ```gleam
/// next_event(events)
/// |> should
/// |> be_ok
/// |> extract_reconnect_error
/// |> extract_login_refusal_code
/// |> be_equal("28P01")
/// |> or_fail_with("Expected a refused login")
/// ```
pub fn extract_reconnect_error(
  result: MatchResult(ConnectionEvent),
) -> MatchResult(ConnectError) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(event) -> error_of(event)
  }
}

fn error_of(event: ConnectionEvent) -> MatchResult(ConnectError) {
  case event {
    ReconnectFailed(error) -> MatchOk(error)
    _other ->
      MatchFailed(AssertionFailure(
        operator: "extract_reconnect_error",
        message: "",
        payload: Some(CustomMatcherFailure(
          actual: inspect(event),
          description: "Expected a ReconnectFailed event",
        )),
      ))
  }
}
