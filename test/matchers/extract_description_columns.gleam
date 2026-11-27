//// Extracts the result columns of a statement description.

import dream_postgres/internal/cell.{
  type ColumnDescription, type StatementDescription,
}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}

/// Gives the result columns of the description, in order.
///
/// ```gleam
/// prepare(connection, statement("SELECT 1 AS id"), 5000)
/// |> should
/// |> be_ok
/// |> extract_description_columns
/// |> extract_column_names
/// |> be_equal(["id"])
/// |> or_fail_with("Expected the column id")
/// ```
pub fn extract_description_columns(
  result: MatchResult(StatementDescription),
) -> MatchResult(List(ColumnDescription)) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(description) -> MatchOk(description.columns)
  }
}
