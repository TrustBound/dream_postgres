//// Extracts the request failure of a script.

import dream_postgres/driver/connection.{
  type RequestFailure, type ScriptError, ScriptRequestFailed,
}
import dream_test/types.{
  type MatchResult, AssertionFailure, CustomMatcherFailure, MatchFailed, MatchOk,
}
import gleam/option.{Some}
import gleam/string.{inspect}

/// Gives the failure of a `ScriptRequestFailed`. Fails for other errors.
///
/// ```gleam
/// run_script(stopped, statement("SELECT 1"), 5000)
/// |> should
/// |> be_error
/// |> extract_script_request_failure
/// |> be_equal(ConnectionProcessDown)
/// |> or_fail_with("Expected ConnectionProcessDown")
/// ```
pub fn extract_script_request_failure(
  result: MatchResult(ScriptError),
) -> MatchResult(RequestFailure) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(error) -> failure_of(error)
  }
}

fn failure_of(error: ScriptError) -> MatchResult(RequestFailure) {
  case error {
    ScriptRequestFailed(failure) -> MatchOk(failure)
    _other ->
      MatchFailed(AssertionFailure(
        operator: "extract_script_request_failure",
        message: "",
        payload: Some(CustomMatcherFailure(
          actual: inspect(error),
          description: "Expected ScriptRequestFailed",
        )),
      ))
  }
}
