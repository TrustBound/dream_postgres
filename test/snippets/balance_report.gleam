import dream_errors.{type Error}
import dream_postgres/codec.{int}
import dream_postgres/error.{type PostgresError}
import dream_postgres/pool.{type Connection}
import dream_postgres/query.{one, query}
import dream_postgres/row.{single}
import dream_postgres/transaction.{
  RepeatableRead, commit, isolation, keep_both, read_only, step, step_with,
  transaction,
}
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
