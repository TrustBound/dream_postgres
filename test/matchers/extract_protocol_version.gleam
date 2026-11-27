//// Extracts the protocol_version of a login outcome.

import dream_postgres/driver/login.{type LoginOutcome}
import dream_postgres/driver/message.{type ProtocolVersion}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}

/// Gives the `protocol_version` field of the outcome of a login.
///
/// ```gleam
/// log_in(server, test_login)
/// |> should
/// |> be_ok
/// |> extract_protocol_version
/// |> be_equal(expected)
/// |> or_fail_with("Expected the protocol_version")
/// ```
pub fn extract_protocol_version(
  result: MatchResult(LoginOutcome),
) -> MatchResult(ProtocolVersion) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(outcome) -> MatchOk(outcome.protocol_version)
  }
}
