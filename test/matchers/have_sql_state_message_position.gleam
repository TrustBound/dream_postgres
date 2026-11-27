//// A matcher that gives the SQLSTATE, the message and the position of the
//// server error of a client error.

import dream_errors.{type Error}
import dream_postgres/error.{type PostgresError}
import dream_postgres/sql_state.{type SqlState}
import dream_test/types.{
  type MatchResult, AssertionFailure, CustomMatcherFailure, MatchFailed, MatchOk,
}
import gleam/option.{type Option, None, Some}

/// Give the SQLSTATE, the message and the position of the server error
/// that the error holds. The chain fails for an error that holds no server
/// error.
///
/// ## Example
///
/// ```gleam
/// runner.all(query.query("SELEC 1"), single(codec.int), executor, [])
/// |> should
/// |> be_error()
/// |> have_sql_state_message_position()
/// |> be_equal(#(SyntaxError, "syntax error at or near \"SELEC\"", Some(1)))
/// |> or_fail_with("Expected the syntax error at position 1")
/// ```
pub fn have_sql_state_message_position(
  result: MatchResult(Error(PostgresError)),
) -> MatchResult(#(SqlState, String, Option(Int))) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(failure) -> parts_of(failure)
  }
}

fn parts_of(
  failure: Error(PostgresError),
) -> MatchResult(#(SqlState, String, Option(Int))) {
  case error.server_error(failure) {
    Some(server_error) ->
      MatchOk(#(
        server_error.sql_state,
        server_error.message,
        server_error.position,
      ))
    None ->
      MatchFailed(AssertionFailure(
        operator: "have_sql_state_message_position",
        message: "",
        payload: Some(CustomMatcherFailure(
          actual: dream_errors.message(failure),
          description: "expected an error that holds a server error",
        )),
      ))
  }
}
