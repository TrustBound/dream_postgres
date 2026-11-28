//// Extracts the SQLSTATE code of a run that the server refused.

import dream_postgres/driver/connection/request_failure.{
  type RunError, RunRefused,
}
import dream_test/types.{
  type MatchResult, AssertionFailure, CustomMatcherFailure, MatchFailed, MatchOk,
}
import gleam/option.{Some}
import gleam/string.{inspect}

/// Gives the SQLSTATE code of a `RunRefused`. Fails for other errors.
///
/// ```gleam
/// run(connection, statement("SELECT 1/0"), [], [], 5000)
/// |> should
/// |> be_error
/// |> extract_run_refusal_code
/// |> be_equal("22012")
/// |> or_fail_with("Expected 22012")
/// ```
pub fn extract_run_refusal_code(
  result: MatchResult(RunError),
) -> MatchResult(String) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(error) -> code_of(error)
  }
}

fn code_of(error: RunError) -> MatchResult(String) {
  case error {
    RunRefused(report, _status) -> MatchOk(report.code)
    _other ->
      MatchFailed(AssertionFailure(
        operator: "extract_run_refusal_code",
        message: "",
        payload: Some(CustomMatcherFailure(
          actual: inspect(error),
          description: "Expected RunRefused",
        )),
      ))
  }
}
