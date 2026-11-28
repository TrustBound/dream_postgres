//// A transaction as a plan of steps: its options, its steps, and the run
//// that commits it or rolls it back.
////
//// ### A read-only transaction with one snapshot <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/user_report.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
////
//// ```gleam
//// import dream_errors.{type Error}
//// import dream_postgres/codec.{int}
//// import dream_postgres/error.{type PostgresError}
//// import dream_postgres/pool.{type Connection}
//// import dream_postgres/query.{one, query}
//// import dream_postgres/row.{single}
//// import dream_postgres/transaction.{
////   RepeatableRead, commit, isolation, keep_both, read_only, step, transaction,
//// }
//// import gleam/function
////
//// /// The number of users, read in a transaction that sees one snapshot and
//// /// writes nothing.
//// pub fn user_report(
////   connection: Connection,
//// ) -> Result(Int, Error(PostgresError)) {
////   transaction(
////     connection,
////     database: function.identity,
////     rollback_also_failed: keep_both,
////   )
////   |> isolation(RepeatableRead)
////   |> read_only
////   |> step(count_users)
////   |> commit
//// }
////
//// fn count_users(connection: Connection) -> Result(Int, Error(PostgresError)) {
////   query("SELECT count(*) FROM users")
////   |> one(single(int), connection)
//// }
//// ```

import dream_errors.{type Error, Unavailable}
import dream_postgres/error.{
  type PostgresError, type ServerError, CommitRolledBack,
  OptionsInNestedTransaction, PostgresError, RollbackAlsoFailed,
  UnexpectedCommitAnswer,
}
import dream_postgres/internal/connection_state.{
  type HeldConnection, HeldInsideTransaction, HeldOutsideTransaction, NotHeld,
  failed_statement, hold, in_open_transaction, placement, run_held_sql,
  run_held_sql_with_postgres_error,
}
import dream_postgres/internal/failure.{failure}
import dream_postgres/pool.{type Connection}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// The isolation level of a transaction, as PostgreSQL names it.
pub type Isolation {
  /// Each statement sees the rows that were committed before it started.
  /// This is the default of PostgreSQL.
  ReadCommitted
  /// Each statement sees the rows that were committed before the first
  /// statement of the transaction started.
  RepeatableRead
  /// Like `RepeatableRead`, and the commit fails with a serialization
  /// failure when the transactions could not have run one after the other.
  Serializable
}

/// A transaction plan with no step yet. Only such a plan can go to `run`.
pub type NoSteps

/// A transaction plan with one step or more. Such a plan goes to `commit`.
pub type HasSteps

/// The SQL of an isolation level, for `BEGIN`.
@internal
pub fn isolation_sql(isolation: Isolation) -> String {
  case isolation {
    ReadCommitted -> "ISOLATION LEVEL READ COMMITTED"
    RepeatableRead -> "ISOLATION LEVEL REPEATABLE READ"
    Serializable -> "ISOLATION LEVEL SERIALIZABLE"
  }
}

/// Joins the error of a failed step and the error of the `ROLLBACK` after
/// it into one `PostgresError`, for a transaction where every error is a
/// database error. The reason `RollbackAlsoFailed` keeps both errors
/// whole, and `error.sql_state` gives the SQLSTATE of the step.
pub fn keep_both(
  step_error: Error(PostgresError),
  rollback_error: PostgresError,
) -> PostgresError {
  PostgresError(
    query_name: None,
    sql: None,
    reason: RollbackAlsoFailed(step_error:, rollback_error:),
  )
}

/// A transaction plan: its connection, its options and its steps. Nothing
/// is sent before `commit` or `run`. `value` is the result of the last
/// step, `cause` is the cause of the plan's `dream_errors.Error`, and
/// `steps` is `NoSteps` or `HasSteps`.
pub opaque type Transaction(value, cause, steps) {
  Transaction(
    connection: Connection,
    database: fn(PostgresError) -> cause,
    rollback_also_failed: fn(Error(cause), PostgresError) -> cause,
    isolation: Option(Isolation),
    read_only: Bool,
    body: fn(Connection) -> Result(value, Error(cause)),
  )
}

/// A transaction plan on the connection, with no step yet. It sends
/// nothing. The error of the plan is `dream_errors.Error(cause)`.
///
/// - `database` makes the cause of a database error: a database error
///   keeps its kind (`Retry`, `Conflict`, `Unavailable` and so on), and
///   `database` changes only its cause. `function.identity` keeps the
///   `PostgresError`.
/// - `rollback_also_failed` makes the cause for a failed step whose
///   `ROLLBACK` also failed. It gets the error of the step and the error
///   of the rollback, and the plan gives `Unavailable` with that cause.
///   `transaction.keep_both` joins the two into one `PostgresError`.
///
/// On the connection of a transaction, the plan runs as a savepoint: its
/// failure undoes only its own work.
pub fn transaction(
  connection: Connection,
  database database: fn(PostgresError) -> cause,
  rollback_also_failed rollback_also_failed: fn(Error(cause), PostgresError) ->
    cause,
) -> Transaction(Nil, cause, NoSteps) {
  Transaction(
    connection:,
    database:,
    rollback_also_failed:,
    isolation: None,
    read_only: False,
    body: fn(_transaction_connection) { Ok(Nil) },
  )
}

/// Adds a database step: a function of the connection of the
/// transaction. The cause of its error goes through `database`, and its
/// value goes to the next `check` or `step_with`.
pub fn step(
  plan: Transaction(before, cause, steps),
  database_step: fn(Connection) -> Result(value, Error(PostgresError)),
) -> Transaction(value, cause, HasSteps) {
  let Transaction(
    connection:,
    database:,
    rollback_also_failed:,
    isolation:,
    read_only:,
    body:,
  ) = plan
  Transaction(
    connection:,
    database:,
    rollback_also_failed:,
    isolation:,
    read_only:,
    body: fn(transaction_connection) {
      use _before <- result.try(body(transaction_connection))
      database_step(transaction_connection)
      |> result.map_error(dream_errors.map_cause(_, database))
    },
  )
}

/// Adds a database step that takes the value of the step before it.
pub fn step_with(
  plan: Transaction(before, cause, HasSteps),
  database_step: fn(Connection, before) -> Result(value, Error(PostgresError)),
) -> Transaction(value, cause, HasSteps) {
  let Transaction(
    connection:,
    database:,
    rollback_also_failed:,
    isolation:,
    read_only:,
    body:,
  ) = plan
  Transaction(
    connection:,
    database:,
    rollback_also_failed:,
    isolation:,
    read_only:,
    body: fn(transaction_connection) {
      use before <- result.try(body(transaction_connection))
      database_step(transaction_connection, before)
      |> result.map_error(dream_errors.map_cause(_, database))
    },
  )
}

/// Adds a rule on the value of the step before it, with the plan's own
/// error type. An error rolls the transaction back.
pub fn check(
  plan: Transaction(before, cause, HasSteps),
  rule: fn(before) -> Result(value, Error(cause)),
) -> Transaction(value, cause, HasSteps) {
  let Transaction(
    connection:,
    database:,
    rollback_also_failed:,
    isolation:,
    read_only:,
    body:,
  ) = plan
  Transaction(
    connection:,
    database:,
    rollback_also_failed:,
    isolation:,
    read_only:,
    body: fn(transaction_connection) {
      result.try(body(transaction_connection), rule)
    },
  )
}

/// Sets the isolation level of the transaction. A transaction inside a
/// transaction cannot set it, and gives `OptionsInNestedTransaction`.
pub fn isolation(
  plan: Transaction(value, cause, steps),
  isolation: Isolation,
) -> Transaction(value, cause, steps) {
  Transaction(..plan, isolation: Some(isolation))
}

/// Makes the transaction read only: a write in it fails. A transaction
/// inside a transaction cannot set it, and gives
/// `OptionsInNestedTransaction`.
pub fn read_only(
  plan: Transaction(value, cause, steps),
) -> Transaction(value, cause, steps) {
  Transaction(..plan, read_only: True)
}

/// Runs the plan: `BEGIN`, each step in order up to the first error, then
/// `COMMIT`, or `ROLLBACK` after an error. A commit that the server
/// answered with a rollback is `CommitRolledBack`, with the error that
/// failed the transaction. When the `ROLLBACK` after an error also fails,
/// the result is `Unavailable` with the cause that `rollback_also_failed`
/// made from both errors.
pub fn commit(
  plan: Transaction(value, cause, steps),
) -> Result(value, Error(cause)) {
  execute(plan, plan.body)
}

/// Runs the plan with one callback that does all the work with the
/// connection of the transaction. `Ok` commits, and `Error` rolls back. A
/// plan with steps cannot go to `run`.
pub fn run(
  plan: Transaction(Nil, cause, NoSteps),
  callback: fn(Connection) -> Result(value, Error(cause)),
) -> Result(value, Error(cause)) {
  execute(plan, callback)
}

fn execute(
  plan: Transaction(planned, cause, steps),
  body: fn(Connection) -> Result(value, Error(cause)),
) -> Result(value, Error(cause)) {
  case placement(plan.connection) {
    NotHeld ->
      hold(plan.connection, run_outermost(_, plan, body))
      |> result.map_error(fn(reason) {
        plan_error(plan, failure(None, None, reason))
      })
      |> result.flatten
    HeldOutsideTransaction(held:) -> run_outermost(held, plan, body)
    HeldInsideTransaction(held:, savepoints:) ->
      run_nested(held, savepoints, plan, body)
  }
}

// A database error as an error of the plan: the same kind, with the cause
// that `database` makes.
fn plan_error(
  plan: Transaction(planned, cause, steps),
  database_error: Error(PostgresError),
) -> Error(cause) {
  dream_errors.map_cause(database_error, plan.database)
}

fn run_outermost(
  held: HeldConnection,
  plan: Transaction(planned, cause, steps),
  body: fn(Connection) -> Result(value, Error(cause)),
) -> Result(value, Error(cause)) {
  use _begun <- result.try(
    run_held_sql(held, begin_sql(plan)) |> result.map_error(plan_error(plan, _)),
  )
  case body(in_open_transaction(held, 0)) {
    Ok(value) ->
      commit_held(held)
      |> result.replace(value)
      |> result.map_error(plan_error(plan, _))
    Error(step_error) -> undo(held, plan, "ROLLBACK", step_error)
  }
}

fn begin_sql(plan: Transaction(planned, cause, steps)) -> String {
  let modes =
    [
      option.map(plan.isolation, isolation_sql),
      case plan.read_only {
        True -> Some("READ ONLY")
        False -> None
      },
    ]
    |> option.values
  case modes {
    [] -> "BEGIN"
    _ -> "BEGIN " <> string.join(modes, ", ")
  }
}

// Sends COMMIT. The report of a failed statement clears when the
// transaction ends, so it is read before the COMMIT.
fn commit_held(held: HeldConnection) -> Result(Nil, Error(PostgresError)) {
  use aborted_by <- result.try(aborted_by(held, "COMMIT"))
  use results <- result.try(run_held_sql(held, "COMMIT"))
  results
  |> list.map(fn(command_result) { command_result.tag })
  |> commit_answer(aborted_by)
}

/// What the command tags of the answer to `COMMIT` mean: `COMMIT` is a
/// commit, and `ROLLBACK` is a rollback, with the report of the
/// statement that failed the transaction.
@internal
pub fn commit_answer(
  tags: List(String),
  aborted_by: Option(ServerError),
) -> Result(Nil, Error(PostgresError)) {
  case tags {
    ["COMMIT"] -> Ok(Nil)
    ["ROLLBACK"] -> Error(rolled_back(aborted_by, "COMMIT"))
    _ -> Error(failure(None, Some("COMMIT"), UnexpectedCommitAnswer(tags:)))
  }
}

// The server error that failed the open transaction: from the state of
// the connection, or from the replay.
fn aborted_by(
  held: HeldConnection,
  sql: String,
) -> Result(Option(ServerError), Error(PostgresError)) {
  failed_statement(held)
  |> result.map_error(failure(None, Some(sql), _))
}

fn rolled_back(
  aborted_by: Option(ServerError),
  sql: String,
) -> Error(PostgresError) {
  failure(None, Some(sql), CommitRolledBack(cause: aborted_by))
}

// Rolls back after the error of a step, and gives that error. When the
// rollback fails too, it gives `Unavailable` with the cause that
// `rollback_also_failed` makes from both errors, so neither is lost.
fn undo(
  held: HeldConnection,
  plan: Transaction(planned, cause, steps),
  rollback_sql: String,
  step_error: Error(cause),
) -> Result(value, Error(cause)) {
  case run_held_sql_with_postgres_error(held, rollback_sql) {
    Ok(_rolled_back) -> Error(step_error)
    Error(rollback_error) ->
      Error(Unavailable(
        "the rollback after a failed step failed",
        plan.rollback_also_failed(step_error, rollback_error),
      ))
  }
}

fn run_nested(
  held: HeldConnection,
  savepoints: Int,
  plan: Transaction(planned, cause, steps),
  body: fn(Connection) -> Result(value, Error(cause)),
) -> Result(value, Error(cause)) {
  use _no_options <- result.try(case plan.isolation, plan.read_only {
    None, False -> Ok(Nil)
    Some(_), _ | None, True ->
      Error(plan_error(plan, failure(None, None, OptionsInNestedTransaction)))
  })
  let name = savepoint_name(savepoints + 1)
  use _saved <- result.try(
    run_held_sql(held, "SAVEPOINT " <> name)
    |> result.map_error(plan_error(plan, _)),
  )
  case body(in_open_transaction(held, savepoints + 1)) {
    Ok(value) ->
      release_savepoint(held, plan, name)
      |> result.replace(value)
    Error(step_error) -> undo(held, plan, rollback_to_sql(name), step_error)
  }
}

// The name of the savepoint at a depth. It never comes from the app.
fn savepoint_name(depth: Int) -> String {
  "dream_postgres_savepoint_" <> int.to_string(depth)
}

fn rollback_to_sql(name: String) -> String {
  "ROLLBACK TO SAVEPOINT " <> name <> "; RELEASE SAVEPOINT " <> name
}

// Releases the savepoint of a nested transaction that succeeded. When a
// statement in it failed, the savepoint is rolled back instead, so the
// outer transaction can go on, and the result is `CommitRolledBack`.
fn release_savepoint(
  held: HeldConnection,
  plan: Transaction(planned, cause, steps),
  name: String,
) -> Result(Nil, Error(cause)) {
  let release_sql = "RELEASE SAVEPOINT " <> name
  use aborted_by <- result.try(
    aborted_by(held, release_sql) |> result.map_error(plan_error(plan, _)),
  )
  case aborted_by {
    None ->
      run_held_sql(held, release_sql)
      |> result.replace(Nil)
      |> result.map_error(plan_error(plan, _))
    Some(_report) ->
      undo(
        held,
        plan,
        rollback_to_sql(name),
        plan_error(plan, rolled_back(aborted_by, release_sql)),
      )
  }
}
