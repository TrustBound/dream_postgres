import dream_postgres/client.{
  type Connection, type QueryError, type Returned, execute, numeric_as_text,
  numeric_text_decoder, query, returning,
}
import gleam/dynamic/decode.{at}

pub fn price(connection: Connection) -> Result(Returned(String), QueryError) {
  "SELECT 1.5::numeric(10,2)"
  |> query
  |> numeric_as_text
  |> returning(at([0], numeric_text_decoder()))
  |> execute(connection)
}
