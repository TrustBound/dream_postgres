//// A matcher that reads the channel and the payload of each message of a
//// subscription.

import dream_postgres.{
  type ListenMessage, ListenFailed, Listening, NotListening, NotificationArrived,
}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}
import gleam/list
import gleam/string

/// Read the channel and the payload of each message, in order. A message
/// that is no notification gives its name, and its error or an empty
/// payload, so it
/// shows in the comparison.
///
/// ## Example
///
/// ```gleam
/// pools
/// |> should
/// |> collect_with_listener(messages, within: 500, work: notify_after_listen)
/// |> extract_listen_payloads()
/// |> be_equal([#("jobs", "hello")])
/// |> or_fail_with("Expected the notification")
/// ```
pub fn extract_listen_payloads(
  result: MatchResult(List(ListenMessage)),
) -> MatchResult(List(#(String, String))) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(messages) -> MatchOk(list.map(messages, channel_and_payload))
  }
}

fn channel_and_payload(message: ListenMessage) -> #(String, String) {
  case message {
    NotificationArrived(channel:, payload:, process_id: _) -> #(
      channel,
      payload,
    )
    NotListening -> #("NotListening", "")
    Listening(channel:) -> #("Listening " <> channel, "")
    ListenFailed(channel:, error:) -> #(
      "ListenFailed " <> channel,
      string.inspect(error),
    )
  }
}
