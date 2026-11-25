import dream_postgres/client as postgres
import gleam/dynamic/decode
import gleam/time/calendar.{type Date}

pub fn next_day(
  connection: postgres.Connection,
  value: Date,
) -> Result(postgres.Returned(Date), postgres.QueryError) {
  "SELECT $1::date + 1"
  |> postgres.query
  |> postgres.parameter(postgres.calendar_date(value))
  |> postgres.returning(decode.at([0], postgres.calendar_date_decoder()))
  |> postgres.execute(connection)
}
