//// Tracks the transaction of a connection from the outcome of each query
//// step.
////
//// The tracker knows the transaction status of the last ReadyForQuery. In
//// a failed transaction it also keeps the server error that aborted it, so
//// that a later command can say why the transaction failed. The error
//// stays until the transaction ends: a status that is not
//// `InFailedTransaction` clears it.
////
//// This module is internal to dream_postgres.

import dream_postgres/driver/cell.{
  type ServerReport, type TransactionStatus, Idle, InFailedTransaction,
  InTransaction,
}
import dream_postgres/driver/query/step.{
  type Failure, type Outcome, type SimpleQueryFailure, SimpleQueryFailure,
  failure_report,
}
import gleam/option.{type Option, None, or}

/// The transaction status of a connection, and the error that aborted its
/// transaction while that transaction is failed.
pub opaque type TransactionTracker {
  TransactionTracker(
    status: TransactionStatus,
    aborting_error: Option(ServerReport),
  )
}

/// The tracker of a new connection: not in a transaction.
///
/// ## Returns
///
/// A tracker with the status `Idle` and no error.
pub fn new_tracker() -> TransactionTracker {
  TransactionTracker(status: Idle, aborting_error: None)
}

/// Updates the tracker from the status of a ReadyForQuery and the server
/// error of the step before it.
///
/// ## Parameters
///
/// - `tracker`: the tracker before the step
/// - `status`: the transaction status of the step's ReadyForQuery
/// - `error`: the server error of the step, if it had one
///
/// ## Returns
///
/// The tracker with the new status. In a failed transaction it keeps the
/// error that it already has; it takes `error` only when it has none.
/// Outside a failed transaction it has no error.
pub fn track(
  tracker: TransactionTracker,
  status: TransactionStatus,
  error: Option(ServerReport),
) -> TransactionTracker {
  case status {
    InFailedTransaction ->
      TransactionTracker(
        status:,
        aborting_error: or(tracker.aborting_error, error),
      )
    Idle | InTransaction -> TransactionTracker(status:, aborting_error: None)
  }
}

/// Updates the tracker from the outcome of a prepare or run step.
///
/// ## Parameters
///
/// - `tracker`: the tracker before the step
/// - `outcome`: the finished outcome of the step
///
/// ## Returns
///
/// The tracker after the step, as `track` gives it.
pub fn track_step(
  tracker: TransactionTracker,
  outcome: Outcome(value, Failure),
) -> TransactionTracker {
  track(tracker, outcome.status, step_error(outcome.result))
}

/// Updates the tracker from the outcome of a simple query step.
///
/// ## Parameters
///
/// - `tracker`: the tracker before the step
/// - `outcome`: the finished outcome of the step
///
/// ## Returns
///
/// The tracker after the step, as `track` gives it.
pub fn track_simple_query(
  tracker: TransactionTracker,
  outcome: Outcome(value, SimpleQueryFailure),
) -> TransactionTracker {
  track(tracker, outcome.status, simple_query_error(outcome.result))
}

/// The transaction status of the last step.
///
/// ## Parameters
///
/// - `tracker`: the tracker
///
/// ## Returns
///
/// The status of the last ReadyForQuery, or `Idle` before any step.
pub fn transaction_status(tracker: TransactionTracker) -> TransactionStatus {
  tracker.status
}

/// The server error that aborted the current transaction.
///
/// ## Parameters
///
/// - `tracker`: the tracker
///
/// ## Returns
///
/// - `Some(report)`: the transaction is failed, and this error aborted it
/// - `None`: the transaction is not failed, or no tracked step saw the
///   error that aborted it
pub fn aborting_error(tracker: TransactionTracker) -> Option(ServerReport) {
  tracker.aborting_error
}

fn step_error(step_result: Result(value, Failure)) -> Option(ServerReport) {
  case step_result {
    Ok(_) -> None
    Error(failure) -> failure_report(failure)
  }
}

fn simple_query_error(
  simple_query_result: Result(value, SimpleQueryFailure),
) -> Option(ServerReport) {
  case simple_query_result {
    Ok(_) -> None
    Error(SimpleQueryFailure(failure:, ..)) -> failure_report(failure)
  }
}
