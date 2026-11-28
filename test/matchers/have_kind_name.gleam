//// A matcher that gives the kind name of a client error.

import dream_errors.{type Error}
import dream_postgres/error.{type PostgresError}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}

/// Give the kind name of the error, for example `unavailable`.
///
/// ## Example
///
/// ```gleam
/// query("SELECT 1")
/// |> all(single(codec.int), stopped)
/// |> should
/// |> be_error()
/// |> have_kind_name()
/// |> be_equal("unavailable")
/// |> or_fail_with("Expected unavailable")
/// ```
pub fn have_kind_name(
  result: MatchResult(Error(PostgresError)),
) -> MatchResult(String) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(failure) -> MatchOk(dream_errors.kind_name(failure))
  }
}
