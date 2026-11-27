//// Extracts the reason of a lost connection.

import dream_postgres/driver/connection.{
  type LossReason, type RequestFailure, ConnectionLost,
}
import dream_test/types.{
  type MatchResult, AssertionFailure, CustomMatcherFailure, MatchFailed, MatchOk,
}
import gleam/option.{Some}
import gleam/string.{inspect}

/// Gives the reason of `ConnectionLost`, whatever it is: a socket failure
/// or a close after a deadline. Fails for other errors.
///
/// ```gleam
/// copy_from(connection, "COPY t FROM STDIN", 5000, send_across_close(_, proxy))
/// |> should
/// |> be_error
/// |> extract_copy_driver_error
/// |> extract_loss_reason
/// |> or_fail_with("Expected the loss of the connection")
/// ```
pub fn extract_loss_reason(
  result: MatchResult(RequestFailure),
) -> MatchResult(LossReason) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(value) -> reason_of(value)
  }
}

fn reason_of(value: RequestFailure) -> MatchResult(LossReason) {
  case value {
    ConnectionLost(reason) -> MatchOk(reason)
    _other ->
      MatchFailed(AssertionFailure(
        operator: "extract_loss_reason",
        message: "",
        payload: Some(CustomMatcherFailure(
          actual: inspect(value),
          description: "Expected ConnectionLost",
        )),
      ))
  }
}
