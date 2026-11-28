import dream_errors.{type Error}
import dream_postgres/codec.{array, int}
import dream_postgres/error.{type PostgresError}
import dream_postgres/pool.{type Connection}
import dream_postgres/query.{all, parameter, query}
import dream_postgres/row.{single}

/// The ids of the list that a post has.
pub fn existing_post_ids(
  connection: Connection,
  ids: List(Int),
) -> Result(List(Int), Error(PostgresError)) {
  "SELECT id FROM posts WHERE id = any($1) ORDER BY id"
  |> query
  |> parameter(array(int), ids)
  |> all(single(int), connection)
}
