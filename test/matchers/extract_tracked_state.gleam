//// Extracts the transaction status and the aborting error code of a
//// transaction tracker.

import dream_postgres/driver/cell.{type ServerReport, type TransactionStatus}
import dream_postgres/driver/transaction.{
  type TransactionTracker, aborting_error, transaction_status,
}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}
import gleam/option.{type Option, map}

/// Gives `#(status, code)`: the transaction status, and the SQLSTATE code
/// of the error that aborted the transaction, if one did.
///
/// ```gleam
/// tracker
/// |> should
/// |> extract_tracked_state
/// |> be_equal(#(InFailedTransaction, Some("22012")))
/// |> or_fail_with("Expected the division error")
/// ```
pub fn extract_tracked_state(
  result: MatchResult(TransactionTracker),
) -> MatchResult(#(TransactionStatus, Option(String))) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(tracker) ->
      MatchOk(#(transaction_status(tracker), map(aborting_error(tracker), code)))
  }
}

fn code(report: ServerReport) -> String {
  report.code
}
