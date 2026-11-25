import dream_postgres/client as postgres
import gleam/dynamic/decode

pub fn ends_at(
  connection: postgres.Connection,
  sql: String,
) -> Result(postgres.Returned(postgres.Timestamp), postgres.QueryError) {
  sql
  |> postgres.query
  |> postgres.returning(decode.at(
    [0],
    postgres.finite_timestamp(postgres.timestamp_decoder(), "ends_at"),
  ))
  |> postgres.execute(connection)
}
