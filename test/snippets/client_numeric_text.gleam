import dream_postgres/client as postgres
import gleam/dynamic/decode

pub fn add_one_cent(
  connection: postgres.Connection,
  amount: String,
) -> Result(postgres.Returned(String), postgres.QueryError) {
  "SELECT $1::numeric + 0.01"
  |> postgres.query
  |> postgres.parameter(postgres.numeric_text(amount))
  |> postgres.numeric_as_text
  |> postgres.returning(decode.at([0], postgres.numeric_text_decoder()))
  |> postgres.execute(connection)
}
