import dream_postgres/client.{
  type Connection, type QueryError, type Returned, execute, numeric_as_text,
  numeric_text, numeric_text_decoder, parameter, query, returning,
}
import gleam/dynamic/decode.{at}

pub fn add_one_cent(
  connection: Connection,
  amount: String,
) -> Result(Returned(String), QueryError) {
  "SELECT $1::numeric + 0.01"
  |> query
  |> parameter(numeric_text(amount))
  |> numeric_as_text
  |> returning(at([0], numeric_text_decoder()))
  |> execute(connection)
}
