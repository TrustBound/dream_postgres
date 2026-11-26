import dream_postgres/client.{
  type Connection, type QueryError, type Returned, type TimeOfDay,
  calendar_time_of_day_decoder, execute, query, returning,
}
import gleam/dynamic/decode.{at}

pub fn opening_time(
  connection: Connection,
) -> Result(Returned(TimeOfDay), QueryError) {
  "SELECT time '03:04:05'"
  |> query
  |> returning(at([0], calendar_time_of_day_decoder()))
  |> execute(connection)
}
