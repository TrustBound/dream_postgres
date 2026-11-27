//// Extracts the SQLSTATE code of each notice of an outcome.

import dream_postgres/driver/connection.{type Outcome}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}
import gleam/list.{map}

/// Gives the code of each notice that came with the outcome, in order.
///
/// ```gleam
/// run(connection, statement("SELECT 1"), [], [], 5000)
/// |> should
/// |> be_ok
/// |> extract_notice_codes
/// |> be_equal([])
/// |> or_fail_with("Expected no notice")
/// ```
pub fn extract_notice_codes(
  result: MatchResult(Outcome),
) -> MatchResult(List(String)) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(outcome) ->
      MatchOk(map(outcome.notices, fn(notice) { notice.code }))
  }
}
