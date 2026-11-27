//// Extracts what the last query step gave.

import dream_postgres/driver/query.{type Step, type UnexpectedMessage}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}
import matchers/extract_query_feed.{type QueryFeed}

/// Gives the result of the last step of a query feed: the step, or the
/// UnexpectedMessage error.
///
/// ```gleam
/// messages
/// |> should
/// |> extract_query_feed(start.state, step_run)
/// |> extract_last_step
/// |> be_error
/// |> be_equal(expected_error)
/// |> or_fail_with("Expected the UnexpectedMessage")
/// ```
pub fn extract_last_step(
  result: MatchResult(QueryFeed(state, outcome)),
) -> MatchResult(Result(Step(state, outcome), UnexpectedMessage)) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(fed) -> MatchOk(fed.last)
  }
}
