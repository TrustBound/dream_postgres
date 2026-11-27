import dream_errors.{type Error}
import dream_postgres.{
  type Connection, type PostgresError, copy_to, one, query, run, single,
  transaction,
}
import dream_postgres/codec.{int}
import dream_postgres/transaction.{keep_both}
import gleam/function
import gleam/list

/// The number of invoices, in one transaction. The COPY reads each total
/// with a codec that takes no NULL, so a NULL total stops it. The
/// transaction stays usable, and a query counts the invoices instead.
pub fn count_invoices(
  connection: Connection,
) -> Result(Int, Error(PostgresError)) {
  transaction(
    connection,
    database: function.identity,
    rollback_also_failed: keep_both,
  )
  |> run(count_invoices_in_transaction)
}

fn count_invoices_in_transaction(
  connection: Connection,
) -> Result(Int, Error(PostgresError)) {
  let totals =
    copy_to(
      connection,
      query("SELECT total FROM billing.invoices"),
      read: single(int),
      from: [],
      with: list.prepend,
    )
  case totals {
    Ok(all_totals) -> Ok(list.length(all_totals))
    Error(_null_total) ->
      query("SELECT count(*) FROM billing.invoices")
      |> one(single(int), connection)
  }
}
