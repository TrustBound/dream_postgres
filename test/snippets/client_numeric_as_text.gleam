import dream_postgres/client.{
  type Connection, type QueryError, type Returned, execute, numeric_as_text,
  numeric_text_decoder, query, returning,
}
import gleam/dynamic/decode.{at}

pub fn exact_total(
  connection: Connection,
) -> Result(Returned(String), QueryError) {
  "SELECT 12345678901234567.89::numeric(20,2) + 0.01"
  |> query
  |> numeric_as_text
  |> returning(at([0], numeric_text_decoder()))
  |> execute(connection)
}
