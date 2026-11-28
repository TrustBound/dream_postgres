//// A matcher that gives the client failure of an error of a connect to a
//// server at a host and port.

import dream_postgres/driver/connection/event.{type ConnectError}
import dream_postgres/error.{type ConnectFailure}
import dream_postgres/internal/driver_executor
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}

/// Give the client failure of an error of a connect to the server at
/// `host` and `port`.
///
/// ## Example
///
/// ```gleam
/// connection_event.SetupTimedOut
/// |> should
/// |> map_connect_failure("db", 5432)
/// |> be_equal(error.SetupTimedOut)
/// |> or_fail_with("Expected SetupTimedOut")
/// ```
pub fn map_connect_failure(
  result: MatchResult(ConnectError),
  host: String,
  port: Int,
) -> MatchResult(ConnectFailure) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(connect_error) ->
      MatchOk(driver_executor.connect_failure(connect_error, host, port))
  }
}
