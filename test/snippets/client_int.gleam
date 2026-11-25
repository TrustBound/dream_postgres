import dream_postgres/client as postgres
import gleam/dynamic/decode

pub fn next_number(
  connection: postgres.Connection,
  value: Int,
) -> Result(postgres.Returned(Int), postgres.QueryError) {
  "SELECT $1::int + 1"
  |> postgres.query
  |> postgres.parameter(postgres.int(value))
  |> postgres.returning(decode.at([0], decode.int))
  |> postgres.execute(connection)
}
