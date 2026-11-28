//// A matcher that gives the kind of a client error and its reason in
//// short.

import dream_errors.{type Error}
import dream_postgres/error.{type PostgresError, type Reason}
import dream_postgres/sql_state
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}
import gleam/int
import gleam/option.{None, Some}
import gleam/string

/// Give the kind name of the error, a space, and its reason in short: the
/// SQLSTATE of a server error, `CommitRolledBack` and the SQLSTATE of a
/// rolled back commit, `SqlStatementFailed`, the number of statements
/// that ran and the SQLSTATE of a failed later statement of a `run_sql` call,
/// `RollbackAlsoFailed` with the summary of the step error and the reason
/// of the rollback error, the reason itself for each other reason, or
/// `no cause` for an error with no cause.
///
/// ## Example
///
/// ```gleam
/// query("SELECT 1 / 0")
/// |> one(single(codec.int), connection)
/// |> should
/// |> be_error()
/// |> summarise_error()
/// |> be_equal("invalid 22012")
/// |> or_fail_with("Expected a division by zero")
/// ```
pub fn summarise_error(
  result: MatchResult(Error(PostgresError)),
) -> MatchResult(String) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(failure) -> MatchOk(summary(failure))
  }
}

fn summary(failure: Error(PostgresError)) -> String {
  dream_errors.kind_name(failure) <> " " <> cause_summary(failure)
}

fn cause_summary(failure: Error(PostgresError)) -> String {
  case dream_errors.cause(failure) {
    Some(cause) -> reason_summary(cause.reason)
    None -> "no cause"
  }
}

fn reason_summary(reason: Reason) -> String {
  case reason {
    error.Server(server_error) ->
      sql_state.sql_state_to_string(server_error.sql_state)
    error.CommitRolledBack(cause: Some(server_error)) ->
      "CommitRolledBack "
      <> sql_state.sql_state_to_string(server_error.sql_state)
    error.SqlStatementFailed(statements_run:, server_error:) ->
      "SqlStatementFailed "
      <> int.to_string(statements_run)
      <> " "
      <> sql_state.sql_state_to_string(server_error.sql_state)
    error.RollbackAlsoFailed(step_error:, rollback_error:) ->
      "RollbackAlsoFailed "
      <> summary(step_error)
      <> ", then "
      <> reason_summary(rollback_error.reason)
    _ -> string.inspect(reason)
  }
}
