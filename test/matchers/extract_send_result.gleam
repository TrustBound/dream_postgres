//// Sends bytes on a transport connection, and gives the result.

import dream_postgres/driver/transport.{
  type Connection, type TransportError, send,
}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}

/// Sends the bytes on the connection, and gives the result of `send`.
///
/// ```gleam
/// closed_connection
/// |> should
/// |> extract_send_result(<<"X", 4:32>>)
/// |> be_error
/// |> be_equal(SocketClosed)
/// |> or_fail_with("Expected SocketClosed")
/// ```
pub fn extract_send_result(
  result: MatchResult(Connection),
  bytes: BitArray,
) -> MatchResult(Result(Nil, TransportError)) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(connection) -> MatchOk(send(connection, bytes))
  }
}
