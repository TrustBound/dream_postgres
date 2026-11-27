//// Extracts the type byte of a PostgreSQL backend message.

import dream_test/types.{
  type MatchResult, AssertionFailure, CustomMatcherFailure, MatchFailed, MatchOk,
}
import gleam/option.{Some}

/// Gives the first byte of a message, its type: for example `<<"E">>` for an
/// ErrorResponse. Fails when there are no bytes.
///
/// ```gleam
/// answer
/// |> should
/// |> be_ok
/// |> extract_message_type
/// |> be_equal(<<"E">>)
/// |> or_fail_with("Expected an ErrorResponse")
/// ```
pub fn extract_message_type(
  result: MatchResult(BitArray),
) -> MatchResult(BitArray) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(message) -> type_of(message)
  }
}

fn type_of(message: BitArray) -> MatchResult(BitArray) {
  case message {
    <<type_byte:bytes-size(1), _rest:bits>> -> MatchOk(type_byte)
    _empty ->
      MatchFailed(AssertionFailure(
        operator: "extract_message_type",
        message: "",
        payload: Some(CustomMatcherFailure(
          actual: "<<>>",
          description: "Expected a message, got no bytes",
        )),
      ))
  }
}
