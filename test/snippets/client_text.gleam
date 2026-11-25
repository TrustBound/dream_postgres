import dream_postgres/client as postgres
import gleam/dynamic/decode

pub fn shout(
  connection: postgres.Connection,
  value: String,
) -> Result(postgres.Returned(String), postgres.QueryError) {
  "SELECT upper($1::text)"
  |> postgres.query
  |> postgres.parameter(postgres.text(value))
  |> postgres.returning(decode.at([0], decode.string))
  |> postgres.execute(connection)
}
