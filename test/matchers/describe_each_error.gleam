//// A matcher that gives the log text of each error of a list of errors.

import dream_errors.{type Error}
import dream_postgres/error.{type PostgresError}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}
import gleam/list

/// Give the text of each error, in order, as `error.describe` gives it:
/// the dream_errors kind, then the message.
///
/// ## Example
///
/// ```gleam
/// verify(connection, [[checked(read_user, user_row())]])
/// |> should
/// |> be_error()
/// |> describe_each_error()
/// |> be_equal([
///   "failed: user.read: column 3 (nickname) is int4, and the query reads it with the text codec",
/// ])
/// |> or_fail_with("Expected the changed column")
/// ```
pub fn describe_each_error(
  result: MatchResult(List(Error(PostgresError))),
) -> MatchResult(List(String)) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(failures) -> MatchOk(list.map(failures, error.describe_error))
  }
}
