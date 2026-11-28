//// Extracts `#(channel, payload)` of each notification of each outcome of the connection process.

import dream_postgres/driver/connection/outcome.{type Notification, type Outcome}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}
import gleam/list.{map}

/// Gives, for each outcome in order, `#(channel, payload)` of each notification that came with it.
///
/// ```gleam
/// outcomes
/// |> should
/// |> be_ok
/// |> extract_outcome_notifications
/// |> be_equal([[], [#("jobs", "done")]])
/// |> or_fail_with("Expected the notification on the last outcome")
/// ```
pub fn extract_outcome_notifications(
  result: MatchResult(List(Outcome)),
) -> MatchResult(List(List(#(String, String)))) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(outcomes) -> MatchOk(map(outcomes, notifications_of))
  }
}

fn notifications_of(outcome: Outcome) -> List(#(String, String)) {
  map(outcome.notifications, parts_of)
}

fn parts_of(notification: Notification) -> #(String, String) {
  #(notification.channel, notification.payload)
}
