//// Extracts the command result of an outcome of the connection process.

import dream_postgres/driver/cell.{type CommandResult}
import dream_postgres/driver/connection/outcome.{type Outcome}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}

/// Gives the rows, the tag and the row count of the outcome.
///
/// ```gleam
/// run(connection, "SELECT 2", [], [], 5000)
/// |> should
/// |> be_ok
/// |> extract_command_result
/// |> extract_command_rows
/// |> be_equal([[Text(<<"2">>)]])
/// |> or_fail_with("Expected the row 2")
/// ```
pub fn extract_command_result(
  result: MatchResult(Outcome),
) -> MatchResult(CommandResult) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(outcome) -> MatchOk(outcome.result)
  }
}
