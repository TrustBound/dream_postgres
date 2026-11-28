//// Extracts the request failure of a run.

import dream_postgres/driver/connection/request_failure.{
  type RequestFailure, type RunError, RunFailed,
}
import dream_test/types.{
  type MatchResult, AssertionFailure, CustomMatcherFailure, MatchFailed, MatchOk,
}
import gleam/option.{Some}
import gleam/string.{inspect}

/// Gives the failure of a `RunFailed`. Fails for other errors.
///
/// ```gleam
/// run(stopped, statement("SELECT 1"), [], [], 5000)
/// |> should
/// |> be_error
/// |> extract_run_failure
/// |> be_equal(ConnectionProcessDown)
/// |> or_fail_with("Expected ConnectionProcessDown")
/// ```
pub fn extract_run_failure(
  result: MatchResult(RunError),
) -> MatchResult(RequestFailure) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(error) -> failure_of(error)
  }
}

fn failure_of(error: RunError) -> MatchResult(RequestFailure) {
  case error {
    RunFailed(failure) -> MatchOk(failure)
    _other ->
      MatchFailed(AssertionFailure(
        operator: "extract_run_failure",
        message: "",
        payload: Some(CustomMatcherFailure(
          actual: inspect(error),
          description: "Expected RunFailed",
        )),
      ))
  }
}
