//// A matcher that gives the client reason of a failed script.

import dream_postgres/driver/connection.{type ScriptError}
import dream_postgres/error.{type Reason}
import dream_postgres/internal/driver_executor
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}
import fixtures/endpoints

/// Give the client reason of a failed script, as the client sees it.
///
/// ## Example
///
/// ```gleam
/// connection.ScriptCopyRefused([])
/// |> should
/// |> map_script_error()
/// |> be_equal(error.CopyStatementRefused(statements_run: 0))
/// |> or_fail_with("Expected CopyStatementRefused")
/// ```
pub fn map_script_error(
  result: MatchResult(ScriptError),
) -> MatchResult(Reason) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(script_error) ->
      MatchOk(driver_executor.script_error_reason(
        script_error,
        endpoints.example_endpoint(),
      ))
  }
}
