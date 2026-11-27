import dream_errors.{type Error}
import dream_postgres.{
  type Connection, type PostgresError, commit, isolation, one, query, read_only,
  single, step, transaction,
}
import dream_postgres/codec.{int}
import dream_postgres/transaction.{RepeatableRead, keep_both}
import gleam/function

/// The number of users, read in a transaction that sees one snapshot and
/// writes nothing.
pub fn user_report(
  connection: Connection,
) -> Result(Int, Error(PostgresError)) {
  transaction(
    connection,
    database: function.identity,
    rollback_also_failed: keep_both,
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
