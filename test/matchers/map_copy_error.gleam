//// A matcher that gives the client reason of a failed COPY of a driver
//// connection.

import dream_postgres/driver/connection/request_failure.{type CopyError}
import dream_postgres/error.{type Reason}
import dream_postgres/query/driver_executor
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}
import fixtures/endpoints

/// Give the client reason of a failed COPY, as the client sees it.
///
/// ## Example
///
/// ```gleam
/// connection_request_failure.AppFailed(error.QueryTimeout(stopped_on_server: True))
/// |> should
/// |> map_copy_error()
/// |> be_equal(error.QueryTimeout(stopped_on_server: True))
/// |> or_fail_with("Expected the reason of the function")
/// ```
pub fn map_copy_error(
  result: MatchResult(CopyError(Reason)),
) -> MatchResult(Reason) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(copy_error) ->
      MatchOk(driver_executor.copy_error_reason(
        copy_error,
        endpoints.example_endpoint(),
      ))
  }
}
