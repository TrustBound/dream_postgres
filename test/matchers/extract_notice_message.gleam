//// A matcher that reads the message of a notice of the client.

import dream_postgres.{type ServerNotice}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}

/// Read the message of the notice. The chain goes on with the message.
///
/// ## Example
///
/// ```gleam
/// notices
/// |> should
/// |> receive_message(notices, within: 5000)
/// |> extract_notice_message()
/// |> be_equal("table \"missing_table_x\" does not exist, skipping")
/// |> or_fail_with("Expected the notice of the DROP")
/// ```
pub fn extract_notice_message(
  result: MatchResult(ServerNotice),
) -> MatchResult(String) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(notice) -> MatchOk(notice.message)
  }
}
