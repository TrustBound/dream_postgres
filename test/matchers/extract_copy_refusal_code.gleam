//// Extracts the SQLSTATE code of a COPY that the server refused.

import dream_postgres/driver/connection/request_failure.{
  type CopyError, CopyRefused,
}
import dream_test/types.{
  type MatchResult, AssertionFailure, CustomMatcherFailure, MatchFailed, MatchOk,
}
import gleam/option.{Some}
import gleam/string.{inspect}

/// Gives the SQLSTATE code of a `CopyRefused`. Fails for other errors.
///
/// ```gleam
/// copy_from(connection, statement("COPY missing FROM STDIN"), 5000, send_rows)
/// |> should
/// |> be_error
/// |> extract_copy_refusal_code
/// |> be_equal("42P01")
/// |> or_fail_with("Expected 42P01")
/// ```
pub fn extract_copy_refusal_code(
  result: MatchResult(CopyError(reason)),
) -> MatchResult(String) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(error) -> code_of(error)
  }
}

fn code_of(error: CopyError(reason)) -> MatchResult(String) {
  case error {
    CopyRefused(report, _status) -> MatchOk(report.code)
    _other ->
      MatchFailed(AssertionFailure(
        operator: "extract_copy_refusal_code",
        message: "",
        payload: Some(CustomMatcherFailure(
          actual: inspect(error),
          description: "Expected CopyRefused",
        )),
      ))
  }
}
