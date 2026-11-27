//// A matcher that checks the row reader of the chain against the columns
//// of a result.

import dream_postgres/error.{type Reason}
import dream_postgres/internal/cell.{type Format}
import dream_postgres/internal/row_reader.{type DescribedColumn, type Row}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}
import fixtures/type_catalog
import gleam/result

/// Check the reader against `columns`, with the types of the test catalog
/// (`fixtures/type_catalog`). The chain goes on with the format that the
/// check asks for each column, or the reason that the reader does not fit.
///
/// ## Example
///
/// ```gleam
/// single(codec.int)
/// |> should
/// |> check_row([described_column.new("id", type_catalog.int4())])
/// |> be_ok()
/// |> be_equal([BinaryFormat])
/// |> or_fail_with("Expected the binary format for the int column")
/// ```
pub fn check_row(
  result: MatchResult(Row(a)),
  columns: List(DescribedColumn),
) -> MatchResult(Result(List(Format), Reason)) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(reader) ->
      MatchOk(
        row_reader.check(reader, columns, type_catalog.lookup)
        |> result.map(row_reader.result_formats),
      )
  }
}
