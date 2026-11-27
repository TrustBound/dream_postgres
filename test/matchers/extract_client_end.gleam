//// Waits for the client of a test proxy to close, and gives the last bytes
//// that it sent.

import dream_test/types.{type MatchResult, MatchFailed, MatchOk}
import driver/proxy.{type ClientEndWatch, client_end}

/// Waits for the end of the client that `watch` watches, and gives the
/// last bytes it sent. The value in the chain, for example the started
/// connection, is not used: the matcher comes after the matchers that
/// check it, so a failed start does not wait for an end that never comes.
///
/// ```gleam
/// start_in_ended_owner(fn() { start(config) })
/// |> should
/// |> be_ok
/// |> be_ok
/// |> extract_client_end(watch)
/// |> be_equal(<<"X", 4:32>>)
/// |> or_fail_with("Expected a Terminate as the last bytes")
/// ```
pub fn extract_client_end(
  result: MatchResult(a),
  watch: ClientEndWatch,
) -> MatchResult(BitArray) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(_value) -> MatchOk(client_end(watch))
  }
}
