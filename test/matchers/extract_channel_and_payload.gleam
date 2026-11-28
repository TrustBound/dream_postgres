//// Extracts `#(channel, payload)` of a notification.

import dream_postgres/driver/connection/outcome.{type Notification}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}

/// Gives the channel and the payload of the notification, without the
/// process ID of the sender.
///
/// ```gleam
/// process.receive(subscriber, 5000)
/// |> should
/// |> be_ok
/// |> extract_arrived_notification
/// |> extract_channel_and_payload
/// |> be_equal(#("jobs", "done"))
/// |> or_fail_with("Expected the notification on jobs")
/// ```
pub fn extract_channel_and_payload(
  result: MatchResult(Notification),
) -> MatchResult(#(String, String)) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(notification) ->
      MatchOk(#(notification.channel, notification.payload))
  }
}
