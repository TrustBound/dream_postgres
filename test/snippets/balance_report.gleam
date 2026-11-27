import dream_errors.{type Error}
import dream_postgres.{
  type Connection, type PostgresError, commit, isolation, one, query, read_only,
  single, step, step_with, transaction,
}
import dream_postgres/codec.{int}
import dream_postgres/transaction.{RepeatableRead, keep_both}
import gleam/function
import gleam/pair
import gleam/result
import snippets/count_users.{count_users}

/// Gives the number of users and the sum of all balances. Both reads see
/// the same snapshot of the database, and the transaction cannot write.
pub fn balance_report(
  connection: Connection,
) -> Result(#(Int, Int), Error(PostgresError)) {
  transaction(
    connection,
    database: function.identity,
    rollback_also_failed: keep_both,
  )
  |> isolation(RepeatableRead)
  |> read_only
  |> step(count_users)
  |> step_with(add_total_balance)
  |> commit
}

fn add_total_balance(
  connection: Connection,
  user_count: Int,
) -> Result(#(Int, Int), Error(PostgresError)) {
  "SELECT coalesce(sum(balance), 0)::bigint FROM accounts"
  |> query
  |> one(single(int), connection)
  |> result.map(pair.new(user_count, _))
}
