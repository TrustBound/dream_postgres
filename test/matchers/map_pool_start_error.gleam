//// A matcher that gives the client reason of an error of a pool start.

import dream_postgres/driver/pool.{type StartError}
import dream_postgres/error.{type Reason}
import dream_postgres/internal/driver_executor
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}

/// Give the client reason of an error of a pool that did not start, as
/// the client sees it.
///
/// ## Example
///
/// ```gleam
/// pool.InvalidSize(0)
/// |> should
/// |> map_pool_start_error()
/// |> be_equal(error.InvalidConfig(error.InvalidPoolSize(0)))
/// |> or_fail_with("Expected InvalidConfig(InvalidPoolSize(0))")
/// ```
pub fn map_pool_start_error(
  result: MatchResult(StartError),
) -> MatchResult(Reason) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(start_error) ->
      MatchOk(driver_executor.start_error_reason(start_error))
  }
}
