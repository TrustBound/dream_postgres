import dream_postgres/client as postgres
import gleam/dynamic/decode

pub fn sort_numbers(
  connection: postgres.Connection,
  values: List(Int),
) -> Result(postgres.Returned(List(Int)), postgres.QueryError) {
  "SELECT array(SELECT unnest($1::int[]) ORDER BY 1)"
  |> postgres.query
  |> postgres.parameter(postgres.array(postgres.int, values))
  |> postgres.returning(decode.at([0], decode.list(decode.int)))
  |> postgres.execute(connection)
}
