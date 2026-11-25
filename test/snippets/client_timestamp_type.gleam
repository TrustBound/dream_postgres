import dream_postgres/client as postgres
import gleam/dynamic/decode

pub fn created_at(
  connection: postgres.Connection,
) -> Result(postgres.Returned(postgres.Timestamp), postgres.QueryError) {
  "SELECT timestamp '2024-01-02 03:04:05'"
  |> postgres.query
  |> postgres.returning(decode.at([0], postgres.timestamp_decoder()))
  |> postgres.execute(connection)
}
