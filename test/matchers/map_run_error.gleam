//// A matcher that gives the client reason of a failed run.

import dream_postgres/driver/connection/request_failure.{type RunError}
import dream_postgres/error.{type Reason}
import dream_postgres/internal/driver_executor
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}
import fixtures/endpoints

/// Give the client reason of a failed run, as the client sees it.
///
/// ## Example
///
/// ```gleam
/// connection_request_failure.RunCopyRefused
/// |> should
/// |> map_run_error()
/// |> be_equal(error.CopyStatementRefused(statements_run: 0))
/// |> or_fail_with("Expected CopyStatementRefused")
/// ```
pub fn map_run_error(result: MatchResult(RunError)) -> MatchResult(Reason) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(run_error) ->
      MatchOk(driver_executor.run_error_reason(
        run_error,
        endpoints.example_endpoint(),
      ))
  }
}
