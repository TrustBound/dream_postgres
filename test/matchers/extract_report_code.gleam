//// Extracts the SQLSTATE code of a server report.

import dream_postgres/driver/cell.{type ServerReport}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}

/// Gives the SQLSTATE code of the report, for example `22012`.
///
/// ```gleam
/// aborted_by(connection)
/// |> should
/// |> be_ok
/// |> be_some
/// |> extract_report_code
/// |> be_equal("22012")
/// |> or_fail_with("Expected 22012")
/// ```
pub fn extract_report_code(
  result: MatchResult(ServerReport),
) -> MatchResult(String) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(report) -> MatchOk(report.code)
  }
}
