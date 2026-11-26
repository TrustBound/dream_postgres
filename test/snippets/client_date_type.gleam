import dream_postgres/client.{
  type Connection, type Date, type QueryError, type Returned,
  calendar_date_decoder, execute, query, returning,
}
import gleam/dynamic/decode.{at}

pub fn birthday(connection: Connection) -> Result(Returned(Date), QueryError) {
  "SELECT date '2024-01-02'"
  |> query
  |> returning(at([0], calendar_date_decoder()))
  |> execute(connection)
}
