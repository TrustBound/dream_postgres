import dream_postgres/client as postgres
import gleam/dynamic/decode
import gleam/result

pub fn answer_in_transaction(
  connection: postgres.Connection,
) -> Result(List(Int), postgres.TransactionError(postgres.QueryError)) {
  use transaction <- postgres.transaction(connection)
  "SELECT 40 + 2"
  |> postgres.query
  |> postgres.returning(decode.at([0], decode.int))
  |> postgres.execute(transaction)
  |> result.map(fn(returned) { returned.rows })
}
