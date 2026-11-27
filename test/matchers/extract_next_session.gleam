//// Extracts the session after a query step, for the next step.

import dream_test/types.{type MatchResult, MatchFailed, MatchOk}
import driver/server_query.{type Session}

/// Gives the session after a step, and drops the outcome of the step.
///
/// ```gleam
/// session
/// |> should
/// |> extract_session_step(start_simple_query("BEGIN"), step_simple_query)
/// |> extract_next_session
/// |> extract_session_step(start_simple_query("COMMIT"), step_simple_query)
/// |> extract_step_outcome
/// |> extract_outcome_status
/// |> be_equal(Idle)
/// |> or_fail_with("Expected Idle after COMMIT")
/// ```
pub fn extract_next_session(
  result: MatchResult(#(outcome, Session)),
) -> MatchResult(Session) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(#(_outcome, session)) -> MatchOk(session)
  }
}
