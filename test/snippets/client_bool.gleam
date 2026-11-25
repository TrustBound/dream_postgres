import dream_postgres/client as postgres
import gleam/dynamic/decode

pub fn negate(
  connection: postgres.Connection,
  value: Bool,
) -> Result(postgres.Returned(Bool), postgres.QueryError) {
  "SELECT NOT $1::bool"
  |> postgres.query
  |> postgres.parameter(postgres.bool(value))
  |> postgres.returning(decode.at([0], decode.bool))
  |> postgres.execute(connection)
}
