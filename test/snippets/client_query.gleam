import dream_postgres/client as postgres
import gleam/dynamic/decode

pub fn add(
  connection: postgres.Connection,
  left: Int,
  right: Int,
) -> Result(postgres.Returned(Int), postgres.QueryError) {
  "SELECT $1::int + $2::int"
  |> postgres.query
  |> postgres.parameter(postgres.int(left))
  |> postgres.parameter(postgres.int(right))
  |> postgres.returning(decode.at([0], decode.int))
  |> postgres.execute(connection)
}
