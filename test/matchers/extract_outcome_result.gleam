//// Extracts the result of a query outcome.

import dream_postgres/driver/query.{type Outcome}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}

/// Gives the `result` field of a query outcome: the value of the query,
/// or its failure.
///
/// ```gleam
/// outcome
/// |> should
/// |> extract_outcome_result
/// |> be_ok
/// |> be_equal(expected_description)
/// |> or_fail_with("Expected the description")
/// ```
pub fn extract_outcome_result(
  result: MatchResult(Outcome(value, failure)),
) -> MatchResult(Result(value, failure)) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(outcome) -> MatchOk(outcome.result)
  }
}
