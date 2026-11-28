//// Extracts the rows of a command result.

import dream_postgres/driver/cell.{type Cell, type CommandResult}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}

/// Gives the rows of a command result, one cell per column.
///
/// ```gleam
/// command
/// |> should
/// |> extract_command_rows
/// |> be_equal([[Text(<<"t":utf8>>)]])
/// |> or_fail_with("Expected the text cell t")
/// ```
pub fn extract_command_rows(
  result: MatchResult(CommandResult),
) -> MatchResult(List(List(Cell))) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(command) -> MatchOk(command.rows)
  }
}
