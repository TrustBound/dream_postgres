import dream_postgres/client as postgres
import gleam/dynamic/decode

pub fn valid_until(
  connection: postgres.Connection,
  sql: String,
) -> Result(postgres.Returned(postgres.Date), postgres.QueryError) {
  sql
  |> postgres.query
  |> postgres.returning(decode.at(
    [0],
    postgres.finite_date(postgres.calendar_date_decoder(), "valid_until"),
  ))
  |> postgres.execute(connection)
}
