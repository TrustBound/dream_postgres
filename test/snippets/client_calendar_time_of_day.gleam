import dream_postgres/client as postgres
import gleam/dynamic/decode
import gleam/time/calendar.{type TimeOfDay}

pub fn one_minute_later(
  connection: postgres.Connection,
  value: TimeOfDay,
) -> Result(postgres.Returned(TimeOfDay), postgres.QueryError) {
  "SELECT $1::time + interval '1 minute'"
  |> postgres.query
  |> postgres.parameter(postgres.calendar_time_of_day(value))
  |> postgres.returning(decode.at([0], postgres.calendar_time_of_day_decoder()))
  |> postgres.execute(connection)
}
