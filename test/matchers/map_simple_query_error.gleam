//// A matcher that gives the client reason of a failed simple query.

import dream_postgres/driver/connection.{type SimpleQueryError}
import dream_postgres/error.{type Reason}
import dream_postgres/internal/driver_executor
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}
import fixtures/endpoints

/// Give the client reason of a failed simple query, as the client sees it.
///
/// ## Example
///
/// ```gleam
/// connection.SimpleQueryCopyRefused([])
/// |> should
/// |> map_simple_query_error()
/// |> be_equal(error.CopyStatementRefused(statements_run: 0))
/// |> or_fail_with("Expected CopyStatementRefused")
/// ```
pub fn map_simple_query_error(
  result: MatchResult(SimpleQueryError),
) -> MatchResult(Reason) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(simple_query_error) ->
      MatchOk(driver_executor.simple_query_error_reason(
        simple_query_error,
        endpoints.example_endpoint(),
      ))
  }
}
