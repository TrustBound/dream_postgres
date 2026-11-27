//// Extracts the outcomes of the statements that ran before a statement of a script failed.

import dream_postgres/driver/connection.{
  type Outcome, type ScriptError, ScriptFailed,
}
import dream_test/types.{
  type MatchResult, AssertionFailure, CustomMatcherFailure, MatchFailed, MatchOk,
}
import gleam/option.{Some}
import gleam/string.{inspect}

/// Gives the outcomes of the statements of `ScriptFailed` that completed
/// before the failed one. Fails for other errors.
///
/// ```gleam
/// run_script(connection, "SELECT 1; SELECT 1/0", 5000)
/// |> should
/// |> be_error
/// |> extract_script_failure_outcomes
/// |> extract_outcome_tags
/// |> be_equal(["SELECT 1"])
/// |> or_fail_with("Expected the statement before the failure")
/// ```
pub fn extract_script_failure_outcomes(
  result: MatchResult(ScriptError),
) -> MatchResult(List(Outcome)) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(error) -> completed_of(error)
  }
}

fn completed_of(error: ScriptError) -> MatchResult(List(Outcome)) {
  case error {
    ScriptFailed(completed, _report, _status) -> MatchOk(completed)
    _other ->
      MatchFailed(AssertionFailure(
        operator: "extract_script_failure_outcomes",
        message: "",
        payload: Some(CustomMatcherFailure(
          actual: inspect(error),
          description: "Expected ScriptFailed",
        )),
      ))
  }
}
