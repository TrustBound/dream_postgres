//// Extracts the transaction_status of a login outcome.

import dream_postgres/driver/cell.{type TransactionStatus}
import dream_postgres/driver/login.{type LoginOutcome}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}

/// Gives the `transaction_status` field of the outcome of a login.
///
/// ```gleam
/// log_in(server, test_login)
/// |> should
/// |> be_ok
/// |> extract_transaction_status
/// |> be_equal(expected)
/// |> or_fail_with("Expected the transaction_status")
/// ```
pub fn extract_transaction_status(
  result: MatchResult(LoginOutcome),
) -> MatchResult(TransactionStatus) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(outcome) -> MatchOk(outcome.transaction_status)
  }
}
