import dream_errors.{type Error}
import dream_postgres.{
  type Connection, type PostgresError, all, parameter, query, single,
}
import dream_postgres/codec.{array, int}

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
