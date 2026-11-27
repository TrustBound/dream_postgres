//// Prints a value as the text that `string.inspect` gives.

import dream_test/types.{type MatchResult, MatchFailed, MatchOk}
import gleam/string.{inspect}

/// Gives the text that `string.inspect` prints for the value, the text a
/// log or a crash report shows.
///
/// ```gleam
/// config
/// |> should
/// |> extract_printed
/// |> not_contain_text("pencil")
/// |> or_fail_with("Expected no password text")
/// ```
pub fn extract_printed(result: MatchResult(a)) -> MatchResult(String) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(value) -> MatchOk(inspect(value))
  }
}
