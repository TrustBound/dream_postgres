import dream_postgres/client as postgres
import gleam/dynamic/decode

pub fn double(
  connection: postgres.Connection,
  value: Float,
) -> Result(postgres.Returned(Float), postgres.QueryError) {
  "SELECT $1::float8 * 2"
  |> postgres.query
  |> postgres.parameter(postgres.float(value))
  |> postgres.returning(decode.at([0], decode.float))
  |> postgres.execute(connection)
}
