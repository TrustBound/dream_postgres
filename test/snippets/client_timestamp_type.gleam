import dream_postgres/client.{
  type Connection, type QueryError, type Returned, type Timestamp, execute,
  query, returning, timestamp_decoder,
}
import gleam/dynamic/decode.{at}

pub fn created_at(
  connection: Connection,
) -> Result(Returned(Timestamp), QueryError) {
  "SELECT timestamp '2024-01-02 03:04:05'"
  |> query
  |> returning(at([0], timestamp_decoder()))
  |> execute(connection)
}
