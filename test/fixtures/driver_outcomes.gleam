//// Outcomes of statements that a driver connection ran, for the tests of
//// the client reason of a failure after them.

import dream_postgres/driver/connection.{type Outcome, Outcome}
import dream_postgres/internal/cell.{CommandResult, Idle}

/// The outcome of an `INSERT` of one row, outside a transaction.
///
/// ## Example
///
/// ```gleam
/// connection.ScriptCopyRefused([driver_outcomes.insert_outcome()])
/// ```
pub fn insert_outcome() -> Outcome {
  Outcome(
    columns: [],
    result: CommandResult(rows: [], tag: "INSERT 0 1", count: 1),
    notices: [],
    notifications: [],
    transaction_status: Idle,
  )
}
