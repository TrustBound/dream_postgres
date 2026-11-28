//// Extracts the report of a login that the server refused.

import dream_postgres/driver/connection/event.{type ConnectError, LoginRefused}
import dream_postgres/driver/login.{ServerRejectedLogin}
import dream_postgres/internal/cell.{type ServerReport}
import dream_test/types.{
  type MatchResult, AssertionFailure, CustomMatcherFailure, MatchFailed, MatchOk,
}
import gleam/option.{Some}
import gleam/string.{inspect}

/// Gives the ErrorResponse report of a login that the server refused.
/// Fails for other start errors.
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
pub fn extract_login_refusal_report(
  result: MatchResult(ConnectError),
) -> MatchResult(ServerReport) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(error) -> report_of(error)
  }
}

fn report_of(error: ConnectError) -> MatchResult(ServerReport) {
  case error {
    LoginRefused(ServerRejectedLogin(report)) -> MatchOk(report)
    _other ->
      MatchFailed(AssertionFailure(
        operator: "extract_login_refusal_report",
        message: "",
        payload: Some(CustomMatcherFailure(
          actual: inspect(error),
          description: "Expected a login that the server rejected",
        )),
      ))
  }
}
