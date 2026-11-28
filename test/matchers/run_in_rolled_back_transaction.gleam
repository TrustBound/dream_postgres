//// A matcher that runs work in a transaction on the pool of the chosen
//// version, and rolls the transaction back, so the work leaves nothing on
//// the server.

import dream_errors.{type Error, Failed}
import dream_postgres/error.{type PostgresError}
import dream_postgres/pool.{type Connection}
import dream_postgres/transaction.{run, transaction}
import dream_test/types.{
  type MatchResult, AssertionFailure, CustomMatcherFailure, MatchFailed, MatchOk,
}
import fixtures/server_pools.{type ServerPools}
import gleam/option.{None, Some}
import gleam/result

/// Why the transaction ended.
type Ending(a) {
  /// The work ran, and its value rolls the transaction back.
  WorkDone(value: a)
  /// The database failed.
  DatabaseFailed(error: PostgresError)
  /// The rollback after the work failed.
  RollbackFailed(work_error: Error(Ending(a)), rollback_error: PostgresError)
}

/// Run `work` in a transaction on the pool of the chosen version, and roll
/// the transaction back. A transaction that `work` starts runs as a
/// savepoint. The chain goes on with what `work` gave.
///
/// ## Example
///
/// ```gleam
/// pools
/// |> should
/// |> run_in_rolled_back_transaction(fn(held) {
///   run_sql("CREATE SCHEMA billing", held)
/// })
/// |> be_ok()
/// |> or_fail_with("Expected the schema in the transaction")
/// ```
pub fn run_in_rolled_back_transaction(
  result: MatchResult(ServerPools),
  work: fn(Connection) -> a,
) -> MatchResult(a) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(pools) ->
      case server_pools.chosen(pools) {
        Ok(pool) -> roll_back(pool.connection, work)
        Error(reason) -> not_run(reason)
      }
  }
}

fn roll_back(
  connection: Connection,
  work: fn(Connection) -> a,
) -> MatchResult(a) {
  let ended =
    transaction(
      connection,
      database: DatabaseFailed,
      rollback_also_failed: RollbackFailed,
    )
    |> run(fn(held) { Error(Failed("rolled back", WorkDone(work(held)))) })
  case result.map_error(ended, dream_errors.cause) {
    Error(Some(WorkDone(value:))) -> MatchOk(value)
    Error(Some(DatabaseFailed(error: failure))) ->
      not_run(error.describe(error.to_dream_error(failure)))
    Error(Some(RollbackFailed(rollback_error:, ..))) ->
      not_run(error.describe(error.to_dream_error(rollback_error)))
    Error(None) -> not_run("the transaction gave NotFound")
    Ok(Nil) -> not_run("the transaction committed")
  }
}

fn not_run(reason: String) -> MatchResult(a) {
  MatchFailed(AssertionFailure(
    operator: "run_in_rolled_back_transaction",
    message: "",
    payload: Some(CustomMatcherFailure(
      actual: reason,
      description: "expected the work to run in a transaction",
    )),
  ))
}
