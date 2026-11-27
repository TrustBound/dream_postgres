//// A matcher that gives the message of a Dream error.

import dream_errors.{type Error}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}

/// Give the message of the error, as a log line shows it.
///
/// ## Example
///
/// ```gleam
/// dream_postgres.config_from_url("postgres://ada:hunter2@host:0/app")
/// |> should
/// |> be_error()
/// |> have_message()
/// |> not_contain_text("hunter2")
/// |> or_fail_with("Expected no password in the message")
/// ```
pub fn have_message(result: MatchResult(Error(cause))) -> MatchResult(String) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(error) -> MatchOk(dream_errors.message(error))
  }
}
