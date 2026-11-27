//// A matcher that gives the client reason of a state question that the connection process did not answer.

import dream_postgres/driver/connection.{type ConnectionStateError}
import dream_postgres/error.{type Reason}
import dream_postgres/internal/driver_executor
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}

/// Give the client reason of a state question that the connection process did not answer, as the client sees it.
///
/// ## Example
///
/// ```gleam
/// connection.ProcessGone
/// |> should
/// |> map_connection_state_error()
/// |> be_equal(error.ConnectionProcessDown)
/// |> or_fail_with("Expected ConnectionProcessDown")
/// ```
pub fn map_connection_state_error(
  result: MatchResult(ConnectionStateError),
) -> MatchResult(Reason) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(state_error) ->
      MatchOk(driver_executor.connection_state_error_reason(state_error))
  }
}
