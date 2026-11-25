import dream_postgres/client as postgres
import gleam/dynamic/decode

pub fn byte_count(
  connection: postgres.Connection,
  value: BitArray,
) -> Result(postgres.Returned(Int), postgres.QueryError) {
  "SELECT length($1::bytea)"
  |> postgres.query
  |> postgres.parameter(postgres.bytea(value))
  |> postgres.returning(decode.at([0], decode.int))
  |> postgres.execute(connection)
}
