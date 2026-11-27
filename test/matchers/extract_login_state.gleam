//// Extracts the first login state of a started login.

import dream_postgres/driver/login.{type LoginMessage, type LoginState}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}

/// Gives the login state that `start` gave with the StartupMessage.
///
/// ```gleam
/// started
/// |> should
/// |> be_ok
/// |> extract_login_state
/// |> extract_state_after([AuthenticationCleartextPassword])
/// |> extract_printed
/// |> not_contain_text("pencil")
/// |> or_fail_with("Expected no password text")
/// ```
pub fn extract_login_state(
  result: MatchResult(#(LoginState, LoginMessage)),
) -> MatchResult(LoginState) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(#(state, _startup)) -> MatchOk(state)
  }
}
