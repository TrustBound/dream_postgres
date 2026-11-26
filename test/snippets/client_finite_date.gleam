import dream_postgres/client.{
  type Connection, type Date, type QueryError, type Returned,
  calendar_date_decoder, execute, finite_date, query, returning,
}
import gleam/dynamic/decode.{at}

pub fn valid_until(
  connection: Connection,
  sql: String,
) -> Result(Returned(Date), QueryError) {
  sql
  |> query
  |> returning(at([0], finite_date(calendar_date_decoder(), "valid_until")))
  |> execute(connection)
}
