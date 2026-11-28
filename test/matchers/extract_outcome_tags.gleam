//// Extracts the command tag of each outcome of the connection process.

import dream_postgres/driver/connection/outcome.{type Outcome}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}
import gleam/list.{map}

/// Gives the command tag of each outcome, in order.
///
/// ```gleam
/// run_simple_query(connection, "SELECT 1", 5000)
/// |> should
/// |> be_ok
/// |> extract_outcome_tags
/// |> be_equal(["SELECT 1"])
/// |> or_fail_with("Expected the tag SELECT 1")
/// ```
pub fn extract_outcome_tags(
  result: MatchResult(List(Outcome)),
) -> MatchResult(List(String)) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(outcomes) -> MatchOk(map(outcomes, tag_of))
  }
}

fn tag_of(outcome: Outcome) -> String {
  outcome.result.tag
}
