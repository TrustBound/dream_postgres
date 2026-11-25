import dream_postgres/client as postgres
import gleam/dynamic/decode

pub fn opening_time(
  connection: postgres.Connection,
) -> Result(postgres.Returned(postgres.TimeOfDay), postgres.QueryError) {
  "SELECT time '03:04:05'"
  |> postgres.query
  |> postgres.returning(decode.at([0], postgres.calendar_time_of_day_decoder()))
  |> postgres.execute(connection)
}
