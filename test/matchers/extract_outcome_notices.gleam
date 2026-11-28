//// Extracts the notice texts of each outcome of the connection process.

import dream_postgres/driver/connection/outcome.{type Outcome}
import dream_postgres/internal/cell.{type ServerReport}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}
import gleam/list.{map}

/// Gives, for each outcome in order, the message of each notice that came with it.
///
/// ```gleam
/// outcomes
/// |> should
/// |> be_ok
/// |> extract_outcome_notices
/// |> be_equal([[], ["hello"]])
/// |> or_fail_with("Expected the notice on the last outcome")
/// ```
pub fn extract_outcome_notices(
  result: MatchResult(List(Outcome)),
) -> MatchResult(List(List(String))) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(outcomes) -> MatchOk(map(outcomes, notices_of))
  }
}

fn notices_of(outcome: Outcome) -> List(String) {
  map(outcome.notices, message_of)
}

fn message_of(report: ServerReport) -> String {
  report.message
}
