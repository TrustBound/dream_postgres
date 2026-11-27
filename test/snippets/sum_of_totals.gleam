import dream_errors.{type Error}
import dream_postgres.{
  type Connection, type PostgresError, copy_to, query, single,
}
import dream_postgres/codec.{int}
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
