import dream_errors.{type Error}
import dream_postgres/codecs.{int}
import dream_postgres/error.{type PostgresError}
import dream_postgres/pool.{type Connection}
import dream_postgres/query.{one, parameter, query}
import dream_postgres/row.{single}
import dream_postgres/transaction.{keep_both, run, transaction}
import gleam/function
import gleam/result

/// Moves the whole balance of an account to another account, and gives
/// the amount. `Ok` from the callback commits, and `Error` rolls back.
pub fn move_balance(
  connection: Connection,
  from from_account: Int,
  to to_account: Int,
) -> Result(Int, Error(PostgresError)) {
  transaction(
    connection,
    database: function.identity,
    rollback_also_failed: keep_both,
  )
  |> run(move_balance_in(_, from_account, to_account))
}

fn move_balance_in(
  transaction_connection: Connection,
  from_account: Int,
  to_account: Int,
) -> Result(Int, Error(PostgresError)) {
  use amount <- result.try(empty_account(transaction_connection, from_account))
  use _new_balance <- result.try(add_to_account(
    transaction_connection,
    to_account,
    amount,
  ))
  Ok(amount)
}

/// Sets the balance of the account to 0, and gives the balance before.
fn empty_account(
  connection: Connection,
  account_id: Int,
) -> Result(Int, Error(PostgresError)) {
  "WITH before AS (SELECT balance FROM accounts WHERE id = $1 FOR UPDATE)
  UPDATE accounts SET balance = 0 FROM before WHERE accounts.id = $1
  RETURNING before.balance"
  |> query
  |> parameter(int, account_id)
  |> one(single(int), connection)
}

/// Adds the amount to the balance of the account. An account that does
/// not exist is `NotFound`, which rolls the transaction back.
fn add_to_account(
  connection: Connection,
  account_id: Int,
  amount: Int,
) -> Result(Int, Error(PostgresError)) {
  "UPDATE accounts SET balance = balance + $1 WHERE id = $2 RETURNING balance"
  |> query
  |> parameter(int, amount)
  |> parameter(int, account_id)
  |> one(single(int), connection)
}
