//// A matcher that gives the SQL of a PostgresError.

import dream_postgres/error.{type PostgresError}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}
import gleam/option.{type Option}

/// Give the SQL of the error, as the error keeps it.
///
/// ## Example
///
/// ```gleam
/// failed
/// |> should
/// |> have_cause()
/// |> have_sql()
/// |> be_equal(Some("SELECT 'sk_test_'"))
/// |> or_fail_with("Expected the secret replaced")
/// ```
pub fn have_sql(
  result: MatchResult(PostgresError),
) -> MatchResult(Option(String)) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(failure) -> MatchOk(failure.sql)
  }
}
