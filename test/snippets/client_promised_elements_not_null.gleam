import dream_postgres/client.{
  type Connection, type QueryError, type Returned, execute,
  promised_elements_not_null, query, returning,
}
import gleam/dynamic/decode.{at, string}

pub fn tags(
  connection: Connection,
) -> Result(Returned(List(String)), QueryError) {
  "SELECT tags FROM posts"
  |> query
  |> returning(at([0], promised_elements_not_null(string, "find.sql", "tags")))
  |> execute(connection)
}
