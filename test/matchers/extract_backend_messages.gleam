//// Decodes bytes into the backend messages they hold.

import dream_postgres/driver/decode.{decode_backend}
import dream_postgres/driver/message.{
  type BackendMessage, type ProtocolError, Decoded, NeedMoreBytes,
}
import dream_test/types.{
  type MatchResult, AssertionFailure, CustomMatcherFailure, MatchFailed, MatchOk,
}
import gleam/list.{reverse}
import gleam/option.{Some}
import gleam/string.{inspect}

/// Decodes every backend message of the bytes, in order. Fails on a
/// protocol error, and when bytes are left after the last whole message.
///
/// ```gleam
/// <<"1", 4:32, "2", 4:32>>
/// |> should
/// |> extract_backend_messages
/// |> be_equal([ParseComplete, BindComplete])
/// |> or_fail_with("Expected ParseComplete and BindComplete")
/// ```
pub fn extract_backend_messages(
  result: MatchResult(BitArray),
) -> MatchResult(List(BackendMessage)) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(bytes) -> decode_all(bytes, [])
  }
}

fn decode_all(
  bytes: BitArray,
  collected: List(BackendMessage),
) -> MatchResult(List(BackendMessage)) {
  case decode_backend(bytes) {
    Ok(Decoded(message, rest)) -> decode_all(rest, [message, ..collected])
    Ok(NeedMoreBytes) -> end_of(bytes, collected)
    Error(error) -> protocol_error(error)
  }
}

fn end_of(
  bytes: BitArray,
  collected: List(BackendMessage),
) -> MatchResult(List(BackendMessage)) {
  case bytes {
    <<>> -> MatchOk(reverse(collected))
    _left -> failure(inspect(bytes), "Expected no bytes after the last message")
  }
}

fn protocol_error(error: ProtocolError) -> MatchResult(List(BackendMessage)) {
  failure(inspect(error), "Expected bytes with no protocol error")
}

fn failure(
  actual: String,
  description: String,
) -> MatchResult(List(BackendMessage)) {
  MatchFailed(AssertionFailure(
    operator: "extract_backend_messages",
    message: "",
    payload: Some(CustomMatcherFailure(actual:, description:)),
  ))
}
