//// Extracts `#(channel, payload)` of each notification from asynchronous messages.

import dream_postgres/driver/query.{type AsynchronousMessage, Notification}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}
import gleam/list.{filter_map}

/// Gives `#(channel, payload)` of each notification in the list, in order. Other messages give nothing.
///
/// ```gleam
/// messages
/// |> should
/// |> extract_notifications
/// |> be_equal([#("jobs", "done")])
/// |> or_fail_with("Expected the notifications")
/// ```
pub fn extract_notifications(
  result: MatchResult(List(AsynchronousMessage)),
) -> MatchResult(List(#(String, String))) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(messages) -> MatchOk(filter_map(messages, pick))
  }
}

fn pick(message: AsynchronousMessage) -> Result(#(String, String), Nil) {
  case message {
    Notification(_process_id, channel, payload) -> Ok(#(channel, payload))
    _other -> Error(Nil)
  }
}
