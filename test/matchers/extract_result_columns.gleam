//// Extracts the result columns of an outcome of the connection process.

import dream_postgres/driver/connection/outcome.{type Outcome}
import dream_postgres/internal/cell.{type ColumnDescription}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}

/// Gives the description of each result column of the outcome, in order.
///
/// ```gleam
/// run(connection, "SELECT 1", [], [], 5000)
/// |> should
/// |> be_ok
/// |> extract_result_columns
/// |> be_equal([ColumnDescription("?column?", 23, -1, 0, 0)])
/// |> or_fail_with("Expected one int4 column")
/// ```
pub fn extract_result_columns(
  result: MatchResult(Outcome),
) -> MatchResult(List(ColumnDescription)) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(outcome) -> MatchOk(outcome.columns)
  }
}
