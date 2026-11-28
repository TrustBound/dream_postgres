//// Extracts the SQLSTATE code of a prepare that the server refused.

import dream_postgres/driver/connection/request_failure.{
  type PrepareError, PrepareRefused,
}
import dream_test/types.{
  type MatchResult, AssertionFailure, CustomMatcherFailure, MatchFailed, MatchOk,
}
import gleam/option.{Some}
import gleam/string.{inspect}

/// Gives the SQLSTATE code of a `PrepareRefused`. Fails for other errors.
///
/// ```gleam
/// prepare(connection, statement("SELEC 1"), 5000)
/// |> should
/// |> be_error
/// |> extract_prepare_refusal_code
/// |> be_equal("42601")
/// |> or_fail_with("Expected 42601")
/// ```
pub fn extract_prepare_refusal_code(
  result: MatchResult(PrepareError),
) -> MatchResult(String) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(error) -> code_of(error)
  }
}

fn code_of(error: PrepareError) -> MatchResult(String) {
  case error {
    PrepareRefused(report, _status) -> MatchOk(report.code)
    _other ->
      MatchFailed(AssertionFailure(
        operator: "extract_prepare_refusal_code",
        message: "",
        payload: Some(CustomMatcherFailure(
          actual: inspect(error),
          description: "Expected PrepareRefused",
        )),
      ))
  }
}
