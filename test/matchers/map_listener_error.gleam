//// A matcher that maps a refused subscribe of the driver to its client reason.

import dream_postgres/driver/listener/process_message.{type ListenerError}
import dream_postgres/error.{type Reason}
import dream_postgres/query/driver_executor
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}

/// Map a refused subscribe of the driver to its client reason. The chain goes on with the result.
///
/// ## Example
///
/// ```gleam
/// listener.ListenerProcessDown
/// |> should
/// |> map_listener_error()
/// |> be_equal(error.ListenerStopped)
/// |> or_fail_with("Expected ListenerStopped")
/// ```
pub fn map_listener_error(
  result: MatchResult(ListenerError),
) -> MatchResult(Reason) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(value) -> MatchOk(driver_executor.listener_error_reason(value))
  }
}
