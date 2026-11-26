import dream_postgres/client.{
  type Connection, type QueryError, type Returned, type Timestamp, execute,
  finite_timestamp, query, returning, timestamp_decoder,
}
import gleam/dynamic/decode.{at}

pub fn ends_at(
  connection: Connection,
  sql: String,
) -> Result(Returned(Timestamp), QueryError) {
  sql
  |> query
  |> returning(at([0], finite_timestamp(timestamp_decoder(), "ends_at")))
  |> execute(connection)
}
