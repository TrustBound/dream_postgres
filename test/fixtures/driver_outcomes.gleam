//// Outcomes of statements that a driver connection ran, for the tests of
//// the client reason of a failure after them.

import dream_postgres/driver/cell.{CommandResult, Idle}
import dream_postgres/driver/connection/outcome.{type Outcome, Outcome}

/// The outcome of an `INSERT` of one row, outside a transaction.
///
/// ## Example
///
/// ```gleam
/// connection_request_failure.SimpleQueryCopyRefused([driver_outcomes.insert_outcome()])
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
