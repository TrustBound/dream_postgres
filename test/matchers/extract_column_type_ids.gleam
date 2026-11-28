//// Extracts the type OID of each column description.

import dream_postgres/driver/cell.{type ColumnDescription}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}
import gleam/list.{map}

/// Gives the type OID of each column description, in order.
///
/// ```gleam
/// prepare(connection, statement("SELECT 1::int4, 'a'::text"), 5000)
/// |> should
/// |> be_ok
/// |> extract_description_columns
/// |> extract_column_type_ids
/// |> be_equal([23, 25])
/// |> or_fail_with("Expected int4 and text")
/// ```
pub fn extract_column_type_ids(
  result: MatchResult(List(ColumnDescription)),
) -> MatchResult(List(Int)) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(columns) -> MatchOk(map(columns, column_type_id))
  }
}

fn column_type_id(column: ColumnDescription) -> Int {
  column.type_id
}
