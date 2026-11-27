//// Checks that a text does not hold a part.

import dream_test/types.{
  type MatchResult, AssertionFailure, CustomMatcherFailure, MatchFailed, MatchOk,
}
import gleam/option.{Some}
import gleam/string.{contains}

/// Passes the text on when it does not hold `part`. Fails when it does.
///
/// ```gleam
/// "LoginConfig(user: \"ada\")"
/// |> should
/// |> not_contain_text("pencil")
/// |> or_fail_with("Expected no password text")
/// ```
pub fn not_contain_text(
  result: MatchResult(String),
  part: String,
) -> MatchResult(String) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(text) -> check(text, part)
  }
}

fn check(text: String, part: String) -> MatchResult(String) {
  case contains(text, part) {
    False -> MatchOk(text)
    True ->
      MatchFailed(AssertionFailure(
        operator: "not_contain_text",
        message: "",
        payload: Some(CustomMatcherFailure(
          actual: text,
          description: "Expected the text not to hold \"" <> part <> "\"",
        )),
      ))
  }
}
