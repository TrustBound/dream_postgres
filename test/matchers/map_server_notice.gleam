//// A matcher that maps a notice report of the driver to the notice of the client.

import dream_postgres.{type ServerNotice}
import dream_postgres/internal/cell.{type ServerReport}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}

/// Map a notice report of the driver to the notice of the client. The chain goes on with the result.
///
/// ## Example
///
/// ```gleam
/// server_reports.unique_violation("NOTICE")
/// |> should
/// |> map_server_notice()
/// |> extract_notice_message()
/// |> be_equal("duplicate key")
/// |> or_fail_with("Expected the message of the report")
/// ```
pub fn map_server_notice(
  result: MatchResult(ServerReport),
) -> MatchResult(ServerNotice) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(value) -> MatchOk(dream_postgres.server_notice(value))
  }
}
