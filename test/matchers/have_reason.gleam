//// A matcher that gives the reason of a PostgresError.

import dream_postgres/error.{type PostgresError, type Reason}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}

/// Give the reason of the error: what went wrong.
///
/// ## Example
///
/// ```gleam
/// PostgresError(query_name: None, sql: None, reason: QueryTimeout(stopped_on_server: True))
/// |> should
/// |> have_reason()
/// |> be_equal(QueryTimeout(stopped_on_server: True))
/// |> or_fail_with("Expected QueryTimeout")
/// ```
pub fn have_reason(result: MatchResult(PostgresError)) -> MatchResult(Reason) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(failure) -> MatchOk(failure.reason)
  }
}
