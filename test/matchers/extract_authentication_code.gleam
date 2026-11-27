//// Extracts the code of a PostgreSQL Authentication message.

import dream_test/types.{
  type MatchResult, AssertionFailure, CustomMatcherFailure, MatchFailed, MatchOk,
}
import gleam/option.{Some}
import gleam/string.{inspect}

/// Gives the code of an Authentication message (type byte `R`): 0 for
/// AuthenticationOk, 3 for a cleartext password, 5 for MD5, 10 for SASL.
/// Fails when the bytes are not an Authentication message.
///
/// ```gleam
/// answer
/// |> should
/// |> be_ok
/// |> extract_authentication_code
/// |> be_equal(10)
/// |> or_fail_with("Expected a SASL login request")
/// ```
pub fn extract_authentication_code(
  result: MatchResult(BitArray),
) -> MatchResult(Int) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(message) -> code_of(message)
  }
}

fn code_of(message: BitArray) -> MatchResult(Int) {
  case message {
    <<"R", _length:32, code:32, _rest:bits>> -> MatchOk(code)
    _other ->
      MatchFailed(AssertionFailure(
        operator: "extract_authentication_code",
        message: "",
        payload: Some(CustomMatcherFailure(
          actual: inspect(message),
          description: "Expected an Authentication message",
        )),
      ))
  }
}
