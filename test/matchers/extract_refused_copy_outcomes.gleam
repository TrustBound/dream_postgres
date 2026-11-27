//// Extracts the outcomes of the statements that ran before a refused COPY.

import dream_postgres/driver/connection.{
  type Outcome, type ScriptError, ScriptCopyRefused,
}
import dream_test/types.{
  type MatchResult, AssertionFailure, CustomMatcherFailure, MatchFailed, MatchOk,
}
import gleam/option.{Some}
import gleam/string.{inspect}

/// Gives the outcomes of the statements of `ScriptCopyRefused` that
/// completed before the COPY. Fails for other errors.
///
/// ```gleam
/// run_script(connection, "SELECT 1; COPY (SELECT 1) TO STDOUT", 5000)
/// |> should
/// |> be_error
/// |> extract_refused_copy_outcomes
/// |> extract_outcome_tags
/// |> be_equal(["SELECT 1"])
/// |> or_fail_with("Expected the statement before the COPY")
/// ```
pub fn extract_refused_copy_outcomes(
  result: MatchResult(ScriptError),
) -> MatchResult(List(Outcome)) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(error) -> completed_of(error)
  }
}

fn completed_of(error: ScriptError) -> MatchResult(List(Outcome)) {
  case error {
    ScriptCopyRefused(completed) -> MatchOk(completed)
    _other ->
      MatchFailed(AssertionFailure(
        operator: "extract_refused_copy_outcomes",
        message: "",
        payload: Some(CustomMatcherFailure(
          actual: inspect(error),
          description: "Expected ScriptCopyRefused",
        )),
      ))
  }
}
