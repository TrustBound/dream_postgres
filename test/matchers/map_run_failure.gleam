//// A matcher that gives what the runner gets from a failed run: a changed
//// statement to check again, or the client reason of the failure.

import dream_postgres/driver/connection/request_failure.{type RunError}
import dream_postgres/query/driver_executor
import dream_postgres/query/runner.{type RunFailure}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}
import fixtures/endpoints

/// Give what the runner gets from a failed run.
///
/// ## Example
///
/// ```gleam
/// connection_request_failure.RunCopyRefused
/// |> should
/// |> map_run_failure()
/// |> be_equal(runner.RunFailed(error.CopyStatementRefused(statements_run: 0)))
/// |> or_fail_with("Expected RunFailed(CopyStatementRefused)")
/// ```
pub fn map_run_failure(
  result: MatchResult(RunError),
) -> MatchResult(RunFailure) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(run_error) ->
      MatchOk(driver_executor.run_failure(
        run_error,
        endpoints.example_endpoint(),
      ))
  }
}
