//// Extracts the detail of each notice of an outcome of the connection process.

import dream_postgres/driver/cell.{type ServerReport}
import dream_postgres/driver/connection/outcome.{type Outcome}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}
import gleam/list.{map}
import gleam/option.{type Option}

/// Gives the detail of each notice that came with the outcome, in order,
/// or `None` for a notice with no detail.
///
/// ```gleam
/// run(connection, sql, [], [], 5000)
/// |> should
/// |> be_ok
/// |> extract_notice_details
/// |> extract_first
/// |> be_some
/// |> contain_string("{QUERY")
/// |> or_fail_with("Expected the query tree in the detail")
/// ```
pub fn extract_notice_details(
  result: MatchResult(Outcome),
) -> MatchResult(List(Option(String))) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(outcome) -> MatchOk(map(outcome.notices, detail_of))
  }
}

fn detail_of(report: ServerReport) -> Option(String) {
  report.detail
}
