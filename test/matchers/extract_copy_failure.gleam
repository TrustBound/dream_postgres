//// Extracts the request failure of a COPY.

import dream_postgres/driver/connection/request_failure.{
  type CopyError, type RequestFailure, CopyFailed,
}
import dream_test/types.{
  type MatchResult, AssertionFailure, CustomMatcherFailure, MatchFailed, MatchOk,
}
import gleam/option.{Some}
import gleam/string.{inspect}

/// Gives the failure of a `CopyFailed`. Fails for other errors.
///
/// ```gleam
/// copy_from(stopped, statement("COPY items FROM STDIN"), 5000, send_rows)
/// |> should
/// |> be_error
/// |> extract_copy_failure
/// |> be_equal(ConnectionProcessDown)
/// |> or_fail_with("Expected ConnectionProcessDown")
/// ```
pub fn extract_copy_failure(
  result: MatchResult(CopyError(reason)),
) -> MatchResult(RequestFailure) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(error) -> failure_of(error)
  }
}

fn failure_of(error: CopyError(reason)) -> MatchResult(RequestFailure) {
  case error {
    CopyFailed(failure) -> MatchOk(failure)
    _other ->
      MatchFailed(AssertionFailure(
        operator: "extract_copy_failure",
        message: "",
        payload: Some(CustomMatcherFailure(
          actual: inspect(error),
          description: "Expected CopyFailed",
        )),
      ))
  }
}
