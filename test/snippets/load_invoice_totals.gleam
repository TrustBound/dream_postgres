import dream_errors.{type Error}
import dream_postgres/codecs.{int}
import dream_postgres/codecs/composite.{type Field, field}
import dream_postgres/copy.{copy_from, table_in_schema}
import dream_postgres/error.{type PostgresError}
import dream_postgres/pool.{type Connection}

/// Stores one invoice row for each total, in the table `invoices` of the
/// schema `billing`.
pub fn load_invoice_totals(
  connection: Connection,
  totals: List(Int),
) -> Result(Int, Error(PostgresError)) {
  copy_from(
    connection,
    into: table_in_schema("billing", "invoices"),
    columns: ["total"],
    rows: totals,
    write: total_fields,
  )
}

fn total_fields(total: Int) -> List(Field) {
  [field(int, total)]
}
