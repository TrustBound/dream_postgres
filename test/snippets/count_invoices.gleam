import dream_errors.{type Error}
import dream_postgres/codec.{int}
import dream_postgres/copy.{copy_to}
import dream_postgres/error.{type PostgresError}
import dream_postgres/pool.{type Connection}
import dream_postgres/query.{one, query}
import dream_postgres/row.{single}
import dream_postgres/transaction.{keep_both, run, transaction}
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
