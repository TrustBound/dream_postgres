import dream_errors.{type Error}
import dream_postgres/codecs.{int, text}
import dream_postgres/error.{type PostgresError}
import dream_postgres/pool.{type Connection}
import dream_postgres/query.{named, one, parameter, query}
import dream_postgres/row.{type Row, column, row}

pub type Post {
  Post(id: Int, user_id: Int, title: String)
}

/// Reads the columns id, user_id and title, in this order, into a Post.
pub fn post_row() -> Row(Post) {
  use id <- column(int)
  use user_id <- column(int)
  use title <- column(text)
  row(Post(id:, user_id:, title:))
}

pub fn create(
  connection: Connection,
  user_id: Int,
  title: String,
) -> Result(Post, Error(PostgresError)) {
  "INSERT INTO posts (user_id, title) VALUES ($1, $2)
RETURNING id, user_id, title"
  |> query
  |> named("post.create")
  |> parameter(int, user_id)
  |> parameter(text, title)
  |> one(post_row(), connection)
}
