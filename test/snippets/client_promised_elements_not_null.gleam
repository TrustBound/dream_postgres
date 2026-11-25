import dream_postgres/client as postgres
import gleam/dynamic/decode

pub fn tags(
  connection: postgres.Connection,
) -> Result(postgres.Returned(List(String)), postgres.QueryError) {
  "SELECT tags FROM posts"
  |> postgres.query
  |> postgres.returning(decode.at(
    [0],
    postgres.promised_elements_not_null(decode.string, "find.sql", "tags"),
  ))
  |> postgres.execute(connection)
}
