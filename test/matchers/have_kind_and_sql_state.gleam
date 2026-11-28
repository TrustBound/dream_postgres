//// A matcher that gives the kind name of a client error and the SQLSTATE
//// of its server error.

import dream_errors.{type Error}
import dream_postgres/error.{type PostgresError}
import dream_postgres/sql_state.{type SqlState}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}
import gleam/option.{type Option}

/// Give the kind name of the error and the SQLSTATE of the server error
/// that it holds, `None` for an error that holds no server error.
///
/// ## Example
///
/// ```gleam
/// runner.affected(duplicate_insert, executor, [])
/// |> should
/// |> be_error()
/// |> have_kind_and_sql_state()
/// |> be_equal(#("conflict", Some(UniqueViolation)))
/// |> or_fail_with("Expected a conflict with the SQLSTATE 23505")
/// ```
pub fn have_kind_and_sql_state(
  result: MatchResult(Error(PostgresError)),
) -> MatchResult(#(String, Option(SqlState))) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(failure) ->
      MatchOk(#(dream_errors.kind_name(failure), error.sql_state(failure)))
  }
}
