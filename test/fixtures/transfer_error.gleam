//// The cause of the error of a transaction plan with a rule of its own,
//// for the tests of `check` and of the error that a transaction gives.

import dream_errors.{type Error, Invalid}
import dream_postgres.{type PostgresError}

/// The cause of the error of a plan that needs more than some number of
/// rows.
pub type TransferError {
  /// The plan found `found` rows, too few.
  NotEnough(found: Int)
  /// The database failed.
  DatabaseFailed(PostgresError)
  /// A step failed, and the rollback after it failed too.
  RollbackFailed(
    step_error: Error(TransferError),
    rollback_error: PostgresError,
  )
}

/// The rule of the plan: `found` is more than `least`.
///
/// ## Example
///
/// ```gleam
/// transfer_error.require_more_than(1, 1)
/// // -> Error(Invalid("too few rows", NotEnough(found: 1)))
/// ```
pub fn require_more_than(
  found: Int,
  least: Int,
) -> Result(Int, Error(TransferError)) {
  case found > least {
    True -> Ok(found)
    False -> Error(Invalid("too few rows", NotEnough(found:)))
  }
}
