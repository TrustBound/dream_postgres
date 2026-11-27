//// Extracts the SQLSTATE code of a script whose first statement the server refused.

import dream_postgres/driver/connection.{type ScriptError, ScriptRefused}
import dream_test/types.{
  type MatchResult, AssertionFailure, CustomMatcherFailure, MatchFailed, MatchOk,
}
import gleam/option.{Some}
import gleam/string.{inspect}

/// Gives the SQLSTATE code of a `ScriptRefused`. Fails for other errors.
///
/// ```gleam
/// run_script(connection, statement("SELECT 1/0"), 5000)
/// |> should
/// |> be_error
/// |> extract_script_refusal_code
/// |> be_equal("22012")
/// |> or_fail_with("Expected 22012")
/// ```
pub fn extract_script_refusal_code(
  result: MatchResult(ScriptError),
) -> MatchResult(String) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(error) -> code_of(error)
  }
}

fn code_of(error: ScriptError) -> MatchResult(String) {
  case error {
    ScriptRefused(report, _status) -> MatchOk(report.code)
    _other ->
      MatchFailed(AssertionFailure(
        operator: "extract_script_refusal_code",
        message: "",
        payload: Some(CustomMatcherFailure(
          actual: inspect(error),
          description: "Expected ScriptRefused",
        )),
      ))
  }
}
