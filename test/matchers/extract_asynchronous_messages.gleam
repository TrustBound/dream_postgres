//// Extracts the asynchronous messages of a query outcome.

import dream_postgres/driver/query.{type AsynchronousMessage, type Outcome}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}

/// Gives the notices, parameter changes and notifications that came while
/// the query ran, in order.
///
/// ```gleam
/// outcome
/// |> should
/// |> extract_asynchronous_messages
/// |> extract_notice_texts
/// |> be_equal(["first", "second"])
/// |> or_fail_with("Expected both notices")
/// ```
pub fn extract_asynchronous_messages(
  result: MatchResult(Outcome(value, failure)),
) -> MatchResult(List(AsynchronousMessage)) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(outcome) -> MatchOk(outcome.asynchronous_messages)
  }
}
