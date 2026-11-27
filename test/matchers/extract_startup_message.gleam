//// Extracts the bytes of the StartupMessage of a started login.

import dream_postgres/driver/login.{
  type LoginMessage, type LoginState, encode_login_message,
}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}

/// Gives the bytes of the StartupMessage that `start` gave with the first
/// login state.
///
/// ```gleam
/// started
/// |> should
/// |> be_ok
/// |> extract_startup_message
/// |> be_equal(startup_message_bytes(0, "ada", [#("database", "shop")]))
/// |> or_fail_with("Expected the StartupMessage")
/// ```
pub fn extract_startup_message(
  result: MatchResult(#(LoginState, LoginMessage)),
) -> MatchResult(BitArray) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(#(_state, startup)) -> MatchOk(encode_login_message(startup))
  }
}
