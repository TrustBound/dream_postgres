//// Extracts the reason of a COPY that the app's function failed.

import dream_postgres/driver/connection.{type CopyError, AppFailed}
import dream_test/types.{
  type MatchResult, AssertionFailure, CustomMatcherFailure, MatchFailed, MatchOk,
}
import gleam/option.{Some}
import gleam/string.{inspect}

/// Gives the reason of `AppFailed`. Fails for a COPY that failed in the
/// driver or on the server.
///
/// ```gleam
/// copy_from(connection, "COPY t FROM STDIN", 5000, send_then_fail)
/// |> should
/// |> be_error
/// |> extract_app_failure
/// |> be_equal("stopped")
/// |> or_fail_with("Expected the app's failure")
/// ```
pub fn extract_app_failure(
  result: MatchResult(CopyError(reason)),
) -> MatchResult(reason) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(value) -> reason_of(value)
  }
}

fn reason_of(value: CopyError(reason)) -> MatchResult(reason) {
  case value {
    AppFailed(reason) -> MatchOk(reason)
    _other ->
      MatchFailed(AssertionFailure(
        operator: "extract_app_failure",
        message: "",
        payload: Some(CustomMatcherFailure(
          actual: inspect(value),
          description: "Expected AppFailed",
        )),
      ))
  }
}
