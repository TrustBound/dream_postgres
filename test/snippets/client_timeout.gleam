import dream_postgres/client as postgres
import gleam/dynamic/decode

pub fn one_in_a_second(
  connection: postgres.Connection,
) -> Result(postgres.Returned(Int), postgres.QueryError) {
  "SELECT 1"
  |> postgres.query
  |> postgres.timeout(1000)
  |> postgres.returning(decode.at([0], decode.int))
  |> postgres.execute(connection)
}
