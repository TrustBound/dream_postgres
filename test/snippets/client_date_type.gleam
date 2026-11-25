import dream_postgres/client as postgres
import gleam/dynamic/decode

pub fn birthday(
  connection: postgres.Connection,
) -> Result(postgres.Returned(postgres.Date), postgres.QueryError) {
  "SELECT date '2024-01-02'"
  |> postgres.query
  |> postgres.returning(decode.at([0], postgres.calendar_date_decoder()))
  |> postgres.execute(connection)
}
