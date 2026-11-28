//// A matcher that maps a failed LISTEN of the driver to its client reason.

import dream_postgres/driver/listener.{type ListenFailure}
import dream_postgres/error.{type Reason}
import dream_postgres/query/driver_executor
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}

/// Map a failed LISTEN of the driver to its client reason. The chain goes on with the result.
///
/// ## Example
///
/// ```gleam
/// listener.ListenAnswerUnexpected
/// |> should
/// |> map_listen_failure()
/// |> be_equal(error.UnexpectedListenAnswer)
/// |> or_fail_with("Expected UnexpectedListenAnswer")
/// ```
pub fn map_listen_failure(
  result: MatchResult(ListenFailure),
) -> MatchResult(Reason) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(value) -> MatchOk(driver_executor.listen_failure_reason(value))
  }
}
