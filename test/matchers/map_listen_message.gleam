//// A matcher that maps a message of the driver's listener to the listen message of the client.

import dream_postgres/driver/listener/process_message
import dream_postgres/listener.{type ListenMessage} as postgres_listener
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}

/// Map a message of the driver's listener to the listen message of the client. The chain goes on with the result.
///
/// ## Example
///
/// ```gleam
/// listener.NotListening
/// |> should
/// |> map_listen_message()
/// |> be_equal(NotListening)
/// |> or_fail_with("Expected NotListening")
/// ```
pub fn map_listen_message(
  result: MatchResult(process_message.ListenerMessage),
) -> MatchResult(ListenMessage) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(value) -> MatchOk(postgres_listener.listen_message(value))
  }
}
