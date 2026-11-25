import dream_postgres/client as postgres
import gleam/dynamic/decode

pub fn price(
  connection: postgres.Connection,
) -> Result(postgres.Returned(String), postgres.QueryError) {
  "SELECT 1.5::numeric(10,2)"
  |> postgres.query
  |> postgres.numeric_as_text
  |> postgres.returning(decode.at([0], postgres.numeric_text_decoder()))
  |> postgres.execute(connection)
}
