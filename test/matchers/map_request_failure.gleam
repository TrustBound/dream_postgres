//// A matcher that gives the client reason of a request that failed on its connection.

import dream_postgres/driver/connection.{type RequestFailure}
import dream_postgres/error.{type Reason}
import dream_postgres/internal/driver_executor
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}

/// Give the client reason of a request that failed on its connection, as the client sees it.
///
/// ## Example
///
/// ```gleam
/// connection.ConnectionProcessDown
/// |> should
/// |> map_request_failure()
/// |> be_equal(error.ConnectionProcessDown)
/// |> or_fail_with("Expected ConnectionProcessDown")
/// ```
pub fn map_request_failure(
  result: MatchResult(RequestFailure),
) -> MatchResult(Reason) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(request_failure) ->
      MatchOk(driver_executor.request_failure_reason(request_failure))
  }
}
