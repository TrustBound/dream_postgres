//// A matcher that checks the row reader of the chain against the columns
//// of a result, and reads a row with it.

import dream_postgres/driver/cell.{type Cell}
import dream_postgres/error.{type Reason}
import dream_postgres/row/reader.{type DescribedColumn, type Row}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}
import fixtures/type_catalog
import gleam/result

/// Check the reader against `columns` and read the row `cells` with it,
/// with the types of the test catalog (`fixtures/type_catalog`). The chain
/// goes on with the value of the row, or the reason that the check or the
/// read failed.
///
/// ## Example
///
/// ```gleam
/// single(codec.int)
/// |> should
/// |> read_row([described_column.new("id", type_catalog.int4())], [Binary(<<7:size(32)>>)])
/// |> be_ok()
/// |> be_equal(7)
/// |> or_fail_with("Expected 7")
/// ```
pub fn read_row(
  result: MatchResult(Row(a)),
  columns: List(DescribedColumn),
  cells: List(Cell),
) -> MatchResult(Result(a, Reason)) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(reader) -> MatchOk(check_and_read(reader, columns, cells))
  }
}

fn check_and_read(
  reader: Row(a),
  columns: List(DescribedColumn),
  cells: List(Cell),
) -> Result(a, Reason) {
  use checked <- result.try(reader.check(reader, columns, type_catalog.lookup))
  reader.read(checked, cells, type_catalog.lookup)
}
