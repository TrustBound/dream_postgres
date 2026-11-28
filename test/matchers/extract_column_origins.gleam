//// Extracts the name, table and column number of each column description.

import dream_postgres/driver/cell.{type ColumnDescription}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}
import gleam/list.{map}

/// Gives, for each column in order, its name, the OID of the table that it
/// comes from, and its column number in that table.
///
/// ```gleam
/// run(connection, "SELECT relname FROM pg_class", [], [], 5000)
/// |> should
/// |> be_ok
/// |> extract_result_columns
/// |> extract_column_origins
/// |> be_equal([#("relname", 1259, 2)])
/// |> or_fail_with("Expected the column of pg_class")
/// ```
pub fn extract_column_origins(
  result: MatchResult(List(ColumnDescription)),
) -> MatchResult(List(#(String, Int, Int))) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(columns) -> MatchOk(map(columns, origin_of))
  }
}

fn origin_of(column: ColumnDescription) -> #(String, Int, Int) {
  #(column.name, column.table_id, column.column_number)
}
