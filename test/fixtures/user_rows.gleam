//// A result of three user columns, `id int4, name text, score numeric`,
//// with its readers and the cells of one row.

import dream_postgres/codec
import dream_postgres/internal/cell.{type Cell, Binary}
import dream_postgres/internal/row_reader.{
  type DescribedColumn, type Row, column, column_at, column_named, row,
}
import fixtures/described_column
import fixtures/type_catalog

/// The columns `id int4, name text, score numeric`.
///
/// ## Example
///
/// ```gleam
/// user_rows.reader()
/// |> should
/// |> check_row(user_rows.columns())
/// ```
pub fn columns() -> List(DescribedColumn) {
  [
    described_column.new("id", type_catalog.int4()),
    described_column.new("name", type_catalog.text()),
    described_column.new("score", type_catalog.numeric()),
  ]
}

/// A reader of each column in order: `#(id, name, score)`.
///
/// ## Example
///
/// ```gleam
/// user_rows.reader()
/// |> should
/// |> read_row(user_rows.columns(), user_rows.cells())
/// // -> Ok(#(7, "Ada", "9.5"))
/// ```
pub fn reader() -> Row(#(Int, String, String)) {
  use id <- column(codec.int)
  use name <- column(codec.text)
  use score <- column(codec.numeric)
  row(#(id, name, score))
}

/// A reader of the score by its position, 3, and of the id by its name:
/// `#(score, id)`. It leaves the name unread.
///
/// ## Example
///
/// ```gleam
/// user_rows.score_and_id_reader()
/// |> should
/// |> read_row(user_rows.columns(), user_rows.cells())
/// // -> Ok(#("9.5", 7))
/// ```
pub fn score_and_id_reader() -> Row(#(String, Int)) {
  use score <- column_at(3, codec.numeric)
  use id <- column_named("id", codec.int)
  row(#(score, id))
}

/// The binary cells of the row `7, 'Ada', 9.5`.
///
/// ## Example
///
/// ```gleam
/// user_rows.cells()
/// // -> [Binary(<<7:size(32)>>), Binary(<<"Ada":utf8>>), Binary(..)]
/// ```
pub fn cells() -> List(Cell) {
  [
    Binary(<<7:size(32)>>),
    Binary(<<"Ada":utf8>>),
    Binary(<<2:16, 0:16, 0:16, 1:16, 9:16, 5000:16>>),
  ]
}
