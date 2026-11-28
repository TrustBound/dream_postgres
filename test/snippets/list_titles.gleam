import dream_errors.{type Error}
import dream_postgres/codecs.{int, text}
import dream_postgres/error.{type PostgresError}
import dream_postgres/pool.{type Connection}
import dream_postgres/query.{all, named, query}
import dream_postgres/row.{type Row, column, row}

/// The id and the title of each post.
pub fn list_titles(
  connection: Connection,
) -> Result(List(#(Int, String)), Error(PostgresError)) {
  query("SELECT id, title FROM posts ORDER BY id")
  |> named("post.list")
  |> all(title_row(), connection)
}

fn title_row() -> Row(#(Int, String)) {
  use id <- column(int)
  use title <- column(text)
  row(#(id, title))
}
