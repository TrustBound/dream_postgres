//// Extracts the SQLSTATE code of a simple query that a later statement failed.

import dream_postgres/driver/connection/request_failure.{
  type SimpleQueryError, SimpleQueryFailed,
}
import dream_test/types.{
  type MatchResult, AssertionFailure, CustomMatcherFailure, MatchFailed, MatchOk,
}
import gleam/option.{Some}
import gleam/string.{inspect}

/// Gives the SQLSTATE code of a `SimpleQueryFailed`. Fails for other errors.
///
/// ```gleam
/// run_simple_query(connection, statement("SELECT 1; SELECT 1/0"), 5000)
/// |> should
/// |> be_error
/// |> extract_simple_query_failure_code
/// |> be_equal("22012")
/// |> or_fail_with("Expected 22012")
/// ```
pub fn extract_simple_query_failure_code(
  result: MatchResult(SimpleQueryError),
) -> MatchResult(String) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(error) -> code_of(error)
  }
}

fn code_of(error: SimpleQueryError) -> MatchResult(String) {
  case error {
    SimpleQueryFailed(_completed, report, _status) -> MatchOk(report.code)
    _other ->
      MatchFailed(AssertionFailure(
        operator: "extract_simple_query_failure_code",
        message: "",
        payload: Some(CustomMatcherFailure(
          actual: inspect(error),
          description: "Expected SimpleQueryFailed",
        )),
      ))
  }
}
