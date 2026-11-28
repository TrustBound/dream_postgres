# Transactions

A transaction runs several statements as one unit: all of them take effect, or none of them. This guide shows the two forms of a transaction, its options, savepoints, and what happens when a statement or the commit fails. The examples use the tables of the [getting started guide](getting-started.md#step-2-make-the-tables).

## Table of Contents

- [A transaction as a pipe of steps](#a-transaction-as-a-pipe-of-steps)
- [Pass a value to the next step](#pass-a-value-to-the-next-step)
- [Isolation and read only](#isolation-and-read-only)
- [A transaction as one callback](#a-transaction-as-one-callback)
- [Savepoints](#savepoints)
- [A commit that rolls back](#a-commit-that-rolls-back)
- [When the rollback fails](#when-the-rollback-fails)

## A transaction as a pipe of steps

A transaction plan starts with `transaction(connection, database:, rollback_also_failed:)`. The plan sends nothing until `commit`. The error of the plan is `dream_errors.Error(cause)`, and the two functions make its cause:

| Argument | What it makes |
|---|---|
| `database` | The cause of a database error. The error keeps its kind, such as `Retry`, `Conflict` or `Unavailable`. Only its cause changes, with `dream_errors.map_cause`. |
| `rollback_also_failed` | The cause for a failed step whose `ROLLBACK` also failed. It gets the error of the step and the `PostgresError` of the rollback. See [When the rollback fails](#when-the-rollback-fails). |

These functions add to the plan:

| Function | What it adds |
|---|---|
| `step(plan, database_step)` | A function of the connection of the transaction. The cause of its error goes through `database`. |
| `step_with(plan, database_step)` | A step that also takes the value of the step before it. |
| `check(plan, rule)` | A rule on the value of the step before it. Its error is a `dream_errors.Error(cause)` of the plan. An error rolls the transaction back. |
| `isolation(plan, level)` | The isolation level. |
| `read_only(plan)` | A read only transaction. |

`commit(plan)` runs the plan: `BEGIN`, each step in order up to the first error, then `COMMIT`. After an error, it sends `ROLLBACK` and gives the error. After success, it gives the value of the last step.

This example has its own cause type, so that a rule can refuse the move:

### Move money between accounts <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/move_money.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
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
```

When the first account has 40 and the move takes 1000, `check` gives `Invalid("not enough funds", NotEnoughFunds(balance: 40, wanted: 1000))`, and the rollback undoes the debit. A database error keeps its kind: a deadlock is `Retry` with the cause `Database(postgres_error)`.

A plan where every error is a database error uses `function.identity` and `transaction.keep_both_errors`. Its errors stay `Error(PostgresError)`, as the next examples show.

## Pass a value to the next step

`step_with` gives a step the value of the step before it. Here the new user goes to the step that opens the account:

### Store a user and an account <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/sign_up.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_errors.{type Error}
import dream_postgres/codec.{int}
import dream_postgres/error.{type PostgresError}
import dream_postgres/pool.{type Connection}
import dream_postgres/query.{one, parameter, query}
import dream_postgres/row.{single}
import dream_postgres/transaction.{
  commit, keep_both_errors, step, step_with, transaction,
}
import gleam/function
import snippets/create_user.{create_user}
import snippets/user_row.{type User}

/// Stores a new user and an account for the user in one transaction, and
/// gives the id of the account.
pub fn sign_up(
  connection: Connection,
  email: String,
  name: String,
) -> Result(Int, Error(PostgresError)) {
  transaction(
    connection,
    database: function.identity,
    rollback_also_failed: keep_both_errors,
  )
  |> step(create_user(_, email, name))
  |> step_with(open_account)
  |> commit
}

/// Opens an account for the user that the step before stored.
fn open_account(
  connection: Connection,
  user: User,
) -> Result(Int, Error(PostgresError)) {
  "INSERT INTO accounts (user_id) VALUES ($1) RETURNING id"
  |> query
  |> parameter(int, user.id)
  |> one(single(int), connection)
}
```

## Isolation and read only

`isolation` sets the isolation level of the transaction, with a value of `dream_postgres/transaction`:

| Level | Each statement sees |
|---|---|
| `ReadCommitted` | The rows that other transactions committed before the statement started. This is the default of PostgreSQL. |
| `RepeatableRead` | The rows that other transactions committed before the first statement of the transaction started. |
| `Serializable` | The same as `RepeatableRead`, and the commit fails with a serialization failure when no order of the transactions, one after the other, gives the same result. |

`read_only` makes a write in the transaction fail. Both go into the `BEGIN` statement:

### A report from one snapshot <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/balance_report.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_errors.{type Error}
import dream_postgres/codec.{int}
import dream_postgres/error.{type PostgresError}
import dream_postgres/pool.{type Connection}
import dream_postgres/query.{one, query}
import dream_postgres/row.{single}
import dream_postgres/transaction.{
  RepeatableRead, commit, isolation, keep_both_errors, read_only, step,
  step_with, transaction,
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
    rollback_also_failed: keep_both_errors,
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
```

A serialization failure is a `Retry` error: nothing happened, and a new run of the whole transaction can succeed.

## A transaction as one callback

`run_transaction(plan, callback)` runs a plan with one callback that does all the work with the connection of the transaction. `Ok` from the callback commits, and `Error` rolls back. Only a plan with no steps can go to `run_transaction`, and the compiler checks this:

### Move a whole balance <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/move_balance.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_errors.{type Error}
import dream_postgres/codec.{int}
import dream_postgres/error.{type PostgresError}
import dream_postgres/pool.{type Connection}
import dream_postgres/query.{one, parameter, query}
import dream_postgres/row.{single}
import dream_postgres/transaction.{
  keep_both_errors, run_transaction, transaction,
}
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
    rollback_also_failed: keep_both_errors,
  )
  |> run_transaction(move_balance_in(_, from_account, to_account))
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
```

When the second account does not exist, `one` gives `NotFound`, and the rollback undoes the first update.

## Savepoints

A transaction on the connection of a transaction runs as a savepoint. Its failure undoes only its own work, and the outer transaction goes on:

### Import users and skip the failures <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/import_users.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_errors.{type Error}
import dream_postgres/error.{type PostgresError}
import dream_postgres/pool.{type Connection}
import dream_postgres/transaction.{
  commit, keep_both_errors, run_transaction, step, transaction,
}
import gleam/function
import gleam/list
import gleam/result
import snippets/create_user.{create_user}
import snippets/user_row.{type User}

/// Stores each person as a user in one transaction, and gives the number
/// of users stored. A person whose email has a user already fails only
/// its own savepoint, and the others are stored.
pub fn import_users(
  connection: Connection,
  people: List(#(String, String)),
) -> Result(Int, Error(PostgresError)) {
  transaction(
    connection,
    database: function.identity,
    rollback_also_failed: keep_both_errors,
  )
  |> run_transaction(import_each(_, people))
}

fn import_each(
  transaction_connection: Connection,
  people: List(#(String, String)),
) -> Result(Int, Error(PostgresError)) {
  people
  |> list.map(import_one(transaction_connection, _))
  |> list.count(result.is_ok)
  |> Ok
}

/// A transaction on the connection of a transaction runs as a savepoint.
fn import_one(
  transaction_connection: Connection,
  person: #(String, String),
) -> Result(User, Error(PostgresError)) {
  let #(email, name) = person
  transaction(
    transaction_connection,
    database: function.identity,
    rollback_also_failed: keep_both_errors,
  )
  |> step(create_user(_, email, name))
  |> commit
}
```

A transaction inside a transaction cannot set `isolation` or `read_only`. Such a plan fails with `OptionsInNestedTransaction`.

A plan that runs on the connection of `with_connection` is not inside a transaction. It sends `BEGIN` and `COMMIT`.

## A commit that rolls back

After a statement fails, PostgreSQL ignores every statement up to the end of the transaction, and it answers `COMMIT` with `ROLLBACK`. When a step drops the error of a failed statement, the plan goes on to `COMMIT`, and the server rolls the transaction back:

### A step that drops an error <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/dropped_error.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_errors.{type Error}
import dream_postgres/error.{type PostgresError}
import dream_postgres/pool.{type Connection}
import dream_postgres/transaction.{commit, keep_both_errors, step, transaction}
import gleam/function
import snippets/create_user.{create_user}

/// A wrong transaction: its step drops the error of a failed statement.
/// PostgreSQL then answers COMMIT with ROLLBACK, and `commit` gives the
/// error of the failed statement.
pub fn create_user_and_drop_error(
  connection: Connection,
  email: String,
  name: String,
) -> Result(Nil, Error(PostgresError)) {
  transaction(
    connection,
    database: function.identity,
    rollback_also_failed: keep_both_errors,
  )
  |> step(insert_and_drop_error(_, email, name))
  |> commit
}

fn insert_and_drop_error(
  connection: Connection,
  email: String,
  name: String,
) -> Result(Nil, Error(PostgresError)) {
  let _dropped_error = create_user(connection, email, name)
  Ok(Nil)
}
```

`commit` then gives a `Failed` error with the reason `CommitRolledBack`. The reason holds the server error of the statement that failed. So `error.sql_state` gives its SQLSTATE, here `UniqueViolation`. A savepoint whose statement failed in the same way rolls back to the savepoint, and gives the same error.

## When the rollback fails

After an error of a step, the plan sends `ROLLBACK`. When the rollback also fails, the plan gives `Unavailable("the rollback after a failed step failed", cause)`. The cause is what `rollback_also_failed` makes from the two errors: the error of the step, and the `PostgresError` of the rollback. No error is lost. `Unavailable` says that the connection or the server failed, and the pool rolls back or replaces that connection when the call ends.

`transaction.keep_both_errors` is the `rollback_also_failed` of a plan with the cause `PostgresError`. It gives a `PostgresError` with the reason `RollbackAlsoFailed(step_error:, rollback_error:)`, which holds both errors. `error.sql_state` and `error.server_error` of the result give the server error of the step.

The same rule applies to `run_transaction`, and to a savepoint whose `ROLLBACK TO SAVEPOINT` fails.
