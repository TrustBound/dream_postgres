import dream_errors.{type Error}
import dream_postgres/codec.{int}
import dream_postgres/copy.{copy_to}
import dream_postgres/error.{type PostgresError}
import dream_postgres/pool.{type Connection}
import dream_postgres/query.{query}
import dream_postgres/row.{single}
import gleam/int

/// The sum of the totals of all invoices. The rows come one at a time, and
/// only the sum stays in memory.
pub fn sum_of_totals(
  connection: Connection,
) -> Result(Int, Error(PostgresError)) {
  copy_to(
    connection,
    query("SELECT total FROM billing.invoices"),
    read: single(int),
    from: 0,
    with: int.add,
  )
}
