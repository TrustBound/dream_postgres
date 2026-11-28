//// Extracts the tag of a command result.

import dream_postgres/driver/cell.{type CommandResult}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}

/// Gives the tag that PostgreSQL sent for the command, for example
/// `SELECT 0`.
///
/// ```gleam
/// run(connection, "SELECT 1", [], [], 5000)
/// |> should
/// |> be_ok
/// |> extract_command_result
/// |> extract_command_tag
/// |> be_equal("SELECT 1")
/// |> or_fail_with("Expected the tag SELECT 1")
/// ```
pub fn extract_command_tag(
  result: MatchResult(CommandResult),
) -> MatchResult(String) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(command) -> MatchOk(command.tag)
  }
}
