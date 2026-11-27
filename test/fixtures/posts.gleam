//// The posts query of the runner tests,
//// `SELECT id, title FROM posts WHERE user_id = $1`, with its statement,
//// its row reader and the cells of its rows.

import dream_postgres/codec
import dream_postgres/internal/cell.{
  type Cell, type StatementDescription, Binary, ParameterDescription,
  StatementDescription,
}
import dream_postgres/internal/query.{type Query}
import dream_postgres/internal/row_reader.{type Row, column, row}
import fixtures/column_description

/// The SQL of the posts query.
///
/// ## Example
///
/// ```gleam
/// query.query(posts.sql())
/// ```
pub fn sql() -> String {
  "SELECT id, title FROM posts WHERE user_id = $1"
}

/// The posts query for the user 7, with no name.
///
/// ## Example
///
/// ```gleam
/// posts.query() |> query.named("post.find")
/// ```
pub fn query() -> Query {
  query.query(sql())
  |> query.parameter(codec.int, 7)
}

/// The description of the prepared posts query: one `int4` parameter, and
/// the columns `id int4, title text`.
///
/// ## Example
///
/// ```gleam
/// fake_executor.returning(posts.statement(), [posts.cells(1, "First")])
/// ```
pub fn statement() -> StatementDescription {
  StatementDescription(parameters: [ParameterDescription(23)], columns: [
    column_description.new("id", 23),
    column_description.new("title", 25),
  ])
}

/// A reader of the posts columns: `#(id, title)`.
///
/// ## Example
///
/// ```gleam
/// runner.all(posts.query(), posts.reader(), executor, [])
/// // -> Ok([#(1, "First")])
/// ```
pub fn reader() -> Row(#(Int, String)) {
  use id <- column(codec.int)
  use title <- column(codec.text)
  row(#(id, title))
}

/// The binary cells of the post `id`, `title`.
///
/// ## Example
///
/// ```gleam
/// posts.cells(1, "First")
/// // -> [Binary(<<1:size(32)>>), Binary(<<"First":utf8>>)]
/// ```
pub fn cells(id: Int, title: String) -> List(Cell) {
  [Binary(<<id:size(32)>>), Binary(<<title:utf8>>)]
}
