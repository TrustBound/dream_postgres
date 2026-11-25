import dream_postgres/client as postgres
import gleam/dynamic/decode

pub fn exact_total(
  connection: postgres.Connection,
) -> Result(postgres.Returned(String), postgres.QueryError) {
  "SELECT 12345678901234567.89::numeric(20,2) + 0.01"
  |> postgres.query
  |> postgres.numeric_as_text
  |> postgres.returning(decode.at([0], postgres.numeric_text_decoder()))
  |> postgres.execute(connection)
}
