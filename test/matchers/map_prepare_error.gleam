//// A matcher that gives the client reason of a failed prepare.

import dream_postgres/driver/connection.{type PrepareError}
import dream_postgres/error.{type Reason}
import dream_postgres/internal/driver_executor
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}
import fixtures/endpoints

/// Give the client reason of a failed prepare, as the client sees it.
///
/// ## Example
///
/// ```gleam
/// connection.PrepareFailed(connection.ConnectionProcessDown)
/// |> should
/// |> map_prepare_error()
/// |> be_equal(error.ConnectionProcessDown)
/// |> or_fail_with("Expected ConnectionProcessDown")
/// ```
pub fn map_prepare_error(
  result: MatchResult(PrepareError),
) -> MatchResult(Reason) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(prepare_error) ->
      MatchOk(driver_executor.prepare_error_reason(
        prepare_error,
        endpoints.example_endpoint(),
      ))
  }
}
