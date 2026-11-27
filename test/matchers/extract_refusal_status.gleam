//// Extracts the transaction status that a refused statement left.

import dream_postgres/driver/connection.{type DriverError, ServerRefused}
import dream_postgres/internal/cell.{type TransactionStatus}
import dream_test/types.{
  type MatchResult, AssertionFailure, CustomMatcherFailure, MatchFailed, MatchOk,
}
import gleam/option.{Some}
import gleam/string.{inspect}

/// Gives the transaction status of a `ServerRefused` error. Fails for
/// other errors.
///
/// ```gleam
/// run(connection, "SELECT * FROM changing", [], [], 5000)
/// |> should
/// |> be_error
/// |> extract_refusal_status
/// |> be_equal(InFailedTransaction)
/// |> or_fail_with("Expected a failed transaction")
/// ```
pub fn extract_refusal_status(
  result: MatchResult(DriverError),
) -> MatchResult(TransactionStatus) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(error) -> refusal_status_of(error)
  }
}

fn refusal_status_of(error: DriverError) -> MatchResult(TransactionStatus) {
  case error {
    ServerRefused(_report, status) -> MatchOk(status)
    _other ->
      MatchFailed(AssertionFailure(
        operator: "extract_refusal_status",
        message: "",
        payload: Some(CustomMatcherFailure(
          actual: inspect(error),
          description: "Expected ServerRefused",
        )),
      ))
  }
}
