//// Extracts the message of a server report.

import dream_postgres/internal/cell.{type ServerReport}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}

/// Gives the primary message of the report.
///
/// ```gleam
/// start(config)
/// |> should
/// |> be_error
/// |> extract_login_refusal_report
/// |> extract_report_message
/// |> be_equal("database \"nothing\" does not exist")
/// |> or_fail_with("Expected the message of the server")
/// ```
pub fn extract_report_message(
  result: MatchResult(ServerReport),
) -> MatchResult(String) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(report) -> MatchOk(report.message)
  }
}
