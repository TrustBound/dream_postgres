//// Extracts the outcome of a query step on a session.

import dream_test/types.{type MatchResult, MatchFailed, MatchOk}
import driver/server_query.{type Session}

/// Gives the outcome of a step, and drops the session after it.
///
/// ```gleam
/// session
/// |> should
/// |> extract_session_step(start_simple_query("SELECT 1"), step_simple_query)
/// |> extract_step_outcome
/// |> extract_outcome_result
/// |> be_ok
/// |> extract_statement_tags
/// |> be_equal([#("SELECT 1", 1)])
/// |> or_fail_with("Expected SELECT 1")
/// ```
pub fn extract_step_outcome(
  result: MatchResult(#(outcome, Session)),
) -> MatchResult(outcome) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(#(outcome, _session)) -> MatchOk(outcome)
  }
}
