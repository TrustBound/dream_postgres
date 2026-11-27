//// A matcher that maps a listener start error of the driver to its client reason.

import dream_postgres/driver/listener.{type StartError}
import dream_postgres/error.{type Reason}
import dream_postgres/internal/driver_executor
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}

/// Map a listener start error of the driver to its client reason. The chain goes on with the result.
///
/// ## Example
///
/// ```gleam
/// listener.ListenerNotStarted(actor.InitTimeout)
/// |> should
/// |> map_listener_start_error("db", 5432)
/// |> be_equal(error.ListenerStartFailed(error.ListenerStartTimedOut))
/// |> or_fail_with("Expected ListenerStartTimedOut")
/// ```
pub fn map_listener_start_error(
  result: MatchResult(StartError),
  host: String,
  port: Int,
) -> MatchResult(Reason) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(value) ->
      MatchOk(driver_executor.listener_start_error_reason(value, host, port))
  }
}
