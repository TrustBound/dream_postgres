//// Extracts the outcomes of the statements that ran before a statement of a simple query failed.

import dream_postgres/driver/connection.{
  type Outcome, type SimpleQueryError, SimpleQueryFailed,
}
import dream_test/types.{
  type MatchResult, AssertionFailure, CustomMatcherFailure, MatchFailed, MatchOk,
}
import gleam/option.{Some}
import gleam/string.{inspect}

/// Gives the outcomes of the statements of `SimpleQueryFailed` that completed
/// before the failed one. Fails for other errors.
///
/// ```gleam
/// run_simple_query(connection, "SELECT 1; SELECT 1/0", 5000)
/// |> should
/// |> be_error
/// |> extract_simple_query_failure_outcomes
/// |> extract_outcome_tags
/// |> be_equal(["SELECT 1"])
/// |> or_fail_with("Expected the statement before the failure")
/// ```
pub fn extract_simple_query_failure_outcomes(
  result: MatchResult(SimpleQueryError),
) -> MatchResult(List(Outcome)) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(error) -> completed_of(error)
  }
}

fn completed_of(error: SimpleQueryError) -> MatchResult(List(Outcome)) {
  case error {
    SimpleQueryFailed(completed, _report, _status) -> MatchOk(completed)
    _other ->
      MatchFailed(AssertionFailure(
        operator: "extract_simple_query_failure_outcomes",
        message: "",
        payload: Some(CustomMatcherFailure(
          actual: inspect(error),
          description: "Expected SimpleQueryFailed",
        )),
      ))
  }
}
