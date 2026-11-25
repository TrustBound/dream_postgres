import dream_postgres/client as postgres
import gleam/dynamic/decode

pub fn order_total(
  connection: postgres.Connection,
) -> Result(postgres.Returned(Int), postgres.QueryError) {
  "SELECT sum(amount)::int AS total FROM orders"
  |> postgres.query
  |> postgres.returning(decode.at(
    [0],
    postgres.promised_not_null(decode.int, "order_total.sql", "total"),
  ))
  |> postgres.execute(connection)
}
