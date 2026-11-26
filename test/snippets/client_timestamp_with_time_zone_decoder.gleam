import dream_postgres/client.{
  type Connection, type QueryError, type Returned, type Timestamp, execute,
  query, returning, timestamp_with_time_zone_decoder,
}
import gleam/dynamic/decode.{at}

pub fn signed_up_at(
  connection: Connection,
) -> Result(Returned(Timestamp), QueryError) {
  "SELECT timestamptz '2024-01-02 03:04:05.25+00'"
  |> query
  |> returning(at([0], timestamp_with_time_zone_decoder()))
  |> execute(connection)
}
