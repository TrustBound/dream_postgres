import dream_errors.{type Error, Invalid}
import dream_postgres/codec.{int}
import dream_postgres/error.{type PostgresError}
import dream_postgres/pool.{type Connection}
import dream_postgres/query.{affected, one, parameter, query}
import dream_postgres/row.{single}
import dream_postgres/transaction.{check, commit, step, transaction}
import gleam/result

/// Why a move of money failed.
pub type MoveMoneyCause {
  /// The first account has less money than the move takes.
  NotEnoughFunds(balance: Int, wanted: Int)
  /// A statement of the move failed.
  Database(PostgresError)
  /// A step failed, and the rollback after it failed too.
  RollbackAlsoFailed(
    step_error: Error(MoveMoneyCause),
    rollback_error: PostgresError,
  )
}

/// Moves money from one account to another in one transaction. Nothing
/// changes when the first account has too little money.
pub fn move_money(
  connection: Connection,
  from: Int,
  to: Int,
  cents: Int,
) -> Result(Nil, Error(MoveMoneyCause)) {
  transaction(
    connection,
    database: Database,
    rollback_also_failed: RollbackAlsoFailed,
  )
  |> step(debit(_, from, cents))
  |> check(require_funds(_, cents))
  |> step(credit(_, to, cents))
  |> commit
}

/// Takes the cents from the account, and gives the new balance.
fn debit(
  connection: Connection,
  account_id: Int,
  cents: Int,
) -> Result(Int, Error(PostgresError)) {
  "UPDATE accounts SET balance = balance - $1 WHERE id = $2 RETURNING balance"
  |> query
  |> parameter(int, cents)
  |> parameter(int, account_id)
  |> one(single(int), connection)
}

/// Refuses a balance below 0 after the debit.
fn require_funds(
  balance_after: Int,
  wanted: Int,
) -> Result(Nil, Error(MoveMoneyCause)) {
  case balance_after >= 0 {
    True -> Ok(Nil)
    False ->
      Error(Invalid(
        "not enough funds",
        NotEnoughFunds(balance: balance_after + wanted, wanted:),
      ))
  }
}

/// Adds the cents to the account.
fn credit(
  connection: Connection,
  account_id: Int,
  cents: Int,
) -> Result(Nil, Error(PostgresError)) {
  "UPDATE accounts SET balance = balance + $1 WHERE id = $2"
  |> query
  |> parameter(int, cents)
  |> parameter(int, account_id)
  |> affected(connection)
  |> result.replace(Nil)
}
