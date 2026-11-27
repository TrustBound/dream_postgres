import dream_errors.{type Error}
import dream_postgres.{
  type Connection, type PostgresError, type Row, all, column, named, query, row,
}
import dream_postgres/codec.{int, text}

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
