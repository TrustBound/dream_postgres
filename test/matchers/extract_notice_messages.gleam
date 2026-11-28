//// Extracts the message of each notice of an outcome of the connection process.

import dream_postgres/driver/connection/outcome.{type Outcome}
import dream_postgres/internal/cell.{type ServerReport}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}
import gleam/list.{map}

/// Gives the message of each notice that came with the outcome, in order.
///
/// ```gleam
/// run(connection, sql, [], [], 5000)
/// |> should
/// |> be_ok
/// |> extract_notice_messages
/// |> be_equal(["row 1", "row 2"])
/// |> or_fail_with("Expected a notice for each row")
/// ```
pub fn extract_notice_messages(
  result: MatchResult(Outcome),
) -> MatchResult(List(String)) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(outcome) -> MatchOk(map(outcome.notices, message_of))
  }
}

fn message_of(report: ServerReport) -> String {
  report.message
}
