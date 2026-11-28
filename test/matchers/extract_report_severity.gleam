//// Extracts the severity of a server report.

import dream_postgres/driver/cell.{type ServerReport}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}

/// Gives the severity of the report, for example `FATAL`.
///
/// ```gleam
/// start(config)
/// |> should
/// |> be_error
/// |> extract_login_refusal_report
/// |> extract_report_severity
/// |> be_equal("FATAL")
/// |> or_fail_with("Expected FATAL")
/// ```
pub fn extract_report_severity(
  result: MatchResult(ServerReport),
) -> MatchResult(String) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(report) -> MatchOk(report.severity)
  }
}
