//// A matcher that gives the client reason of an error of a pool checkout
//// from the pool of a server at a host and port.

import dream_postgres/driver/pool.{type HoldError}
import dream_postgres/error.{type Reason}
import dream_postgres/internal/driver_executor
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}

/// Give the client reason of an error of a pool checkout from the pool of
/// the server at `host` and `port`.
///
/// ## Example
///
/// ```gleam
/// pool.PoolStopped
/// |> should
/// |> map_checkout_error("db", 5432)
/// |> be_equal(error.PoolStopped)
/// |> or_fail_with("Expected PoolStopped")
/// ```
pub fn map_checkout_error(
  result: MatchResult(HoldError),
  host: String,
  port: Int,
) -> MatchResult(Reason) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(checkout_error) ->
      MatchOk(driver_executor.checkout_error_reason(checkout_error, host, port))
  }
}
