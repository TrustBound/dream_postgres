//// Closes a transport connection in a matcher chain.

import dream_postgres/driver/transport.{type Connection, close}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}

/// Closes the connection, and gives the closed connection to the next
/// matcher. Use it to test calls on a closed connection.
///
/// ```gleam
/// connect(config)
/// |> should
/// |> be_ok
/// |> close_connection
/// |> extract_send_result(<<"X", 4:32>>)
/// |> be_error
/// |> be_equal(SocketClosed)
/// |> or_fail_with("Expected SocketClosed")
/// ```
pub fn close_connection(
  result: MatchResult(Connection),
) -> MatchResult(Connection) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(connection) -> {
      close(connection)
      MatchOk(connection)
    }
  }
}
