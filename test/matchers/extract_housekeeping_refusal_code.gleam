//// Extracts the SQLSTATE code of a housekeeping statement that the server
//// refused.

import dream_postgres/driver/connection/request_failure.{
  type HousekeepingError, HousekeepingRefused,
}
import dream_test/types.{
  type MatchResult, AssertionFailure, CustomMatcherFailure, MatchFailed, MatchOk,
}
import gleam/option.{Some}
import gleam/string.{inspect}

/// Gives the SQLSTATE code of a `HousekeepingRefused`. Fails for other
/// errors.
///
/// ```gleam
/// run_housekeeping_simple_query(connection, health_check, 5000)
/// |> should
/// |> be_error
/// |> extract_housekeeping_refusal_code
/// |> be_equal("25P02")
/// |> or_fail_with("Expected 25P02")
/// ```
pub fn extract_housekeeping_refusal_code(
  result: MatchResult(HousekeepingError),
) -> MatchResult(String) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(error) -> code_of(error)
  }
}

fn code_of(error: HousekeepingError) -> MatchResult(String) {
  case error {
    HousekeepingRefused(report, _status) -> MatchOk(report.code)
    _other ->
      MatchFailed(AssertionFailure(
        operator: "extract_housekeeping_refusal_code",
        message: "",
        payload: Some(CustomMatcherFailure(
          actual: inspect(error),
          description: "Expected HousekeepingRefused",
        )),
      ))
  }
}
