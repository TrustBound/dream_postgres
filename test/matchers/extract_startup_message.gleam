//// Extracts the StartupMessage of a started login.

import dream_postgres/driver/login.{type LoginState}
import dream_postgres/driver/message.{type FrontendMessage}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}

/// Gives the StartupMessage that `start` gave with the first login state.
///
/// ```gleam
/// started
/// |> should
/// |> be_ok
/// |> extract_startup_message
/// |> be_equal(expected_startup)
/// |> or_fail_with("Expected the StartupMessage")
/// ```
pub fn extract_startup_message(
  result: MatchResult(#(LoginState, FrontendMessage)),
) -> MatchResult(FrontendMessage) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(#(_state, startup)) -> MatchOk(startup)
  }
}
