import dream_postgres/client as postgres
import gleam/dynamic/decode

pub fn price_with_tax(
  connection: postgres.Connection,
  cents: Int,
) -> Result(postgres.Returned(Float), postgres.QueryError) {
  "SELECT $1::int * 1.25 / 100"
  |> postgres.query
  |> postgres.parameter(postgres.int(cents))
  |> postgres.returning(decode.at([0], postgres.numeric_decoder()))
  |> postgres.execute(connection)
}
