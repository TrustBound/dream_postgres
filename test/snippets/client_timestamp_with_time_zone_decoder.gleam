import dream_postgres/client as postgres
import gleam/dynamic/decode

pub fn signed_up_at(
  connection: postgres.Connection,
) -> Result(postgres.Returned(postgres.Timestamp), postgres.QueryError) {
  "SELECT timestamptz '2024-01-02 03:04:05.25+00'"
  |> postgres.query
  |> postgres.returning(decode.at(
    [0],
    postgres.timestamp_with_time_zone_decoder(),
  ))
  |> postgres.execute(connection)
}
