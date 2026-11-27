//// Receives bytes on a transport connection, and gives the result.

import dream_postgres/driver/transport.{
  type Connection, type ReceiveError, receive,
}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}

/// Waits up to `timeout` milliseconds for bytes on the connection, and
/// gives the result of `receive`.
///
/// ```gleam
/// connection
/// |> should
/// |> extract_receive_result(timeout: 50)
/// |> be_error
/// |> be_equal(ReceiveTimedOut)
/// |> or_fail_with("Expected ReceiveTimedOut")
/// ```
pub fn extract_receive_result(
  result: MatchResult(Connection),
  timeout timeout: Int,
) -> MatchResult(Result(BitArray, ReceiveError)) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(connection) -> MatchOk(receive(connection, timeout))
  }
}
