//// Extracts the name of each column description.

import dream_postgres/driver/cell.{type ColumnDescription}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}
import gleam/list.{map}

/// Gives the name of each column description, in order.
///
/// ```gleam
/// run(connection, "SELECT 1 AS id", [], [], 5000)
/// |> should
/// |> be_ok
/// |> extract_result_columns
/// |> extract_column_names
/// |> be_equal(["id"])
/// |> or_fail_with("Expected the column id")
/// ```
pub fn extract_column_names(
  result: MatchResult(List(ColumnDescription)),
) -> MatchResult(List(String)) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(columns) -> MatchOk(map(columns, column_name))
  }
}

fn column_name(column: ColumnDescription) -> String {
  column.name
}
