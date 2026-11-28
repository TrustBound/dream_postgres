//// Extracts the message of a protocol violation during a request.

import dream_postgres/driver/connection/event.{ProtocolViolation}
import dream_postgres/driver/connection/outcome.{UnexpectedServerMessage}
import dream_postgres/driver/connection/request_failure.{
  type RequestFailure, ConnectionEnded,
}
import dream_postgres/driver/message.{type BackendMessage}
import dream_test/types.{
  type MatchResult, AssertionFailure, CustomMatcherFailure, MatchFailed, MatchOk,
}
import gleam/option.{Some}
import gleam/string.{inspect}

/// Gives the message that the server sent during a request and that the
/// request did not expect. Fails for other errors.
///
/// ```gleam
/// answer
/// |> should
/// |> be_error
/// |> extract_unexpected_server_message
/// |> be_equal(BindComplete)
/// |> or_fail_with("Expected a BindComplete that broke the protocol")
/// ```
pub fn extract_unexpected_server_message(
  result: MatchResult(RequestFailure),
) -> MatchResult(BackendMessage) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(error) -> message_of(error)
  }
}

fn message_of(error: RequestFailure) -> MatchResult(BackendMessage) {
  case error {
    ConnectionEnded(ProtocolViolation(UnexpectedServerMessage(unexpected))) ->
      MatchOk(unexpected.message)
    _other ->
      MatchFailed(AssertionFailure(
        operator: "extract_unexpected_server_message",
        message: "",
        payload: Some(CustomMatcherFailure(
          actual: inspect(error),
          description: "Expected an unexpected server message",
        )),
      ))
  }
}
