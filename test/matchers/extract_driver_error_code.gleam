//// Extracts the SQLSTATE code of a driver error that carries a server report.

import dream_postgres/driver/connection.{
  type DriverError, ScriptFailed, ServerEndedConnection, ServerRefused,
}
import dream_test/types.{
  type MatchResult, AssertionFailure, CustomMatcherFailure, MatchFailed, MatchOk,
}
import gleam/option.{Some}
import gleam/string.{inspect}

/// Gives the SQLSTATE code of the report of a refused statement, of a failed
/// script, or of a session that the server ended. Fails for other errors.
///
/// ```gleam
/// run(connection, "SELECT 1/0", [], [], 5000)
/// |> should
/// |> be_error
/// |> extract_driver_error_code
/// |> be_equal("22012")
/// |> or_fail_with("Expected 22012")
/// ```
pub fn extract_driver_error_code(
  result: MatchResult(DriverError),
) -> MatchResult(String) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(error) -> code_of(error)
  }
}

fn code_of(error: DriverError) -> MatchResult(String) {
  case error {
    ServerRefused(report, _status) -> MatchOk(report.code)
    ScriptFailed(_completed, report, _status) -> MatchOk(report.code)
    ServerEndedConnection(report) -> MatchOk(report.code)
    _other ->
      MatchFailed(AssertionFailure(
        operator: "extract_driver_error_code",
        message: "",
        payload: Some(CustomMatcherFailure(
          actual: inspect(error),
          description: "Expected an error with a server report",
        )),
      ))
  }
}
