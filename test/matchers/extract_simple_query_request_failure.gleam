//// Extracts the request failure of a simple query.

import dream_postgres/driver/connection.{
  type RequestFailure, type SimpleQueryError, SimpleQueryRequestFailed,
}
import dream_test/types.{
  type MatchResult, AssertionFailure, CustomMatcherFailure, MatchFailed, MatchOk,
}
import gleam/option.{Some}
import gleam/string.{inspect}

/// Gives the failure of a `SimpleQueryRequestFailed`. Fails for other errors.
///
/// ```gleam
/// run_simple_query(stopped, statement("SELECT 1"), 5000)
/// |> should
/// |> be_error
/// |> extract_simple_query_request_failure
/// |> be_equal(ConnectionProcessDown)
/// |> or_fail_with("Expected ConnectionProcessDown")
/// ```
pub fn extract_simple_query_request_failure(
  result: MatchResult(SimpleQueryError),
) -> MatchResult(RequestFailure) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(error) -> failure_of(error)
  }
}

fn failure_of(error: SimpleQueryError) -> MatchResult(RequestFailure) {
  case error {
    SimpleQueryRequestFailed(failure) -> MatchOk(failure)
    _other ->
      MatchFailed(AssertionFailure(
        operator: "extract_simple_query_request_failure",
        message: "",
        payload: Some(CustomMatcherFailure(
          actual: inspect(error),
          description: "Expected SimpleQueryRequestFailed",
        )),
      ))
  }
}
