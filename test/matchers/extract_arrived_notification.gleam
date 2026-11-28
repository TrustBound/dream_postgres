//// Extracts the notification of a listener message.

import dream_postgres/driver/connection/outcome.{type Notification}
import dream_postgres/driver/listener/process_message.{
  type ListenerMessage, NotificationArrived,
}
import dream_test/types.{
  type MatchResult, AssertionFailure, CustomMatcherFailure, MatchFailed, MatchOk,
}
import gleam/option.{Some}
import gleam/string.{inspect}

/// Gives the notification of `NotificationArrived`. Fails for
/// `NotListening`, `Listening` and `ListenFailed`.
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
pub fn extract_arrived_notification(
  result: MatchResult(ListenerMessage),
) -> MatchResult(Notification) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(message) -> notification_of(message)
  }
}

fn notification_of(message: ListenerMessage) -> MatchResult(Notification) {
  case message {
    NotificationArrived(notification) -> MatchOk(notification)
    _other ->
      MatchFailed(AssertionFailure(
        operator: "extract_arrived_notification",
        message: "",
        payload: Some(CustomMatcherFailure(
          actual: inspect(message),
          description: "Expected NotificationArrived",
        )),
      ))
  }
}
