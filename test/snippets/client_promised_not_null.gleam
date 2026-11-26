import dream_postgres/client.{
  type Connection, type QueryError, type Returned, execute, promised_not_null,
  query, returning,
}
import gleam/dynamic/decode.{at, int}

pub fn order_total(
  connection: Connection,
) -> Result(Returned(Int), QueryError) {
  "SELECT sum(amount)::int AS total FROM orders"
  |> query
  |> returning(at([0], promised_not_null(int, "order_total.sql", "total")))
  |> execute(connection)
}
