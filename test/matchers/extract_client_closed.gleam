//// Asks a fake server whether its client closed the connection.

import dream_test/types.{type MatchResult, MatchFailed, MatchOk}
import driver/fake_server.{type FakeServer, client_closed}

/// Waits for the fake server to finish with its first client, and gives
/// whether that client closed the connection. The value in the chain, for
/// example the error of the connect, is not used: the matcher comes after
/// the matchers that check it.
///
/// ```gleam
/// try(config, connect)
/// |> should
/// |> be_error
/// |> extract_client_closed(server)
/// |> be_true
/// |> or_fail_with("Expected the client to close its socket")
/// ```
pub fn extract_client_closed(
  result: MatchResult(a),
  server: FakeServer,
) -> MatchResult(Bool) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(_value) -> MatchOk(client_closed(server))
  }
}
