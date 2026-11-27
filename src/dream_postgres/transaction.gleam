//// The options of a transaction, and the types that say whether a
//// transaction plan has steps.
////
//// ### A read-only transaction with one snapshot <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/user_report.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
////
//// ```gleam
//// import dream_errors.{type Error}
//// import dream_postgres.{
////   type Connection, type PostgresError, commit, isolation, one, query, read_only,
////   single, step, transaction,
//// }
//// import dream_postgres/codec.{int}
//// import dream_postgres/transaction.{RepeatableRead, keep_both}
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

import dream_errors.{type Error}
import dream_postgres/error.{
  type PostgresError, PostgresError, RollbackAlsoFailed,
}
import gleam/option.{None}

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
