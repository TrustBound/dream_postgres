//// A matcher that maps a failed unsubscribe of the driver to its client reason.

import dream_postgres/driver/listener.{type UnsubscribeError}
import dream_postgres/error.{type Reason}
import dream_postgres/query/driver_executor
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}

/// Map a failed unsubscribe of the driver to its client reason. The chain goes on with the result.
///
/// ## Example
///
/// ```gleam
/// listener.ListenerGone
/// |> should
/// |> map_unsubscribe_error()
/// |> be_equal(error.ListenerStopped)
/// |> or_fail_with("Expected ListenerStopped")
/// ```
pub fn map_unsubscribe_error(
  result: MatchResult(UnsubscribeError),
) -> MatchResult(Reason) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(value) -> MatchOk(driver_executor.unsubscribe_error_reason(value))
  }
}
