import dream_errors.{type Error}
import dream_postgres/codec.{int}
import dream_postgres/error.{type PostgresError}
import dream_postgres/pool.{type Connection}
import dream_postgres/query.{one, query}
import dream_postgres/row.{single}
import dream_postgres/transaction.{
  RepeatableRead, commit, isolation, keep_both_errors, read_only, step,
  transaction,
}
import gleam/function

/// The number of users, read in a transaction that sees one snapshot and
/// writes nothing.
pub fn user_report(
  connection: Connection,
) -> Result(Int, Error(PostgresError)) {
  transaction(
    connection,
    database: function.identity,
    rollback_also_failed: keep_both_errors,
  )
  |> isolation(RepeatableRead)
  |> read_only
  |> step(count_users)
  |> commit
}

fn count_users(connection: Connection) -> Result(Int, Error(PostgresError)) {
  query("SELECT count(*) FROM users")
  |> one(single(int), connection)
}
