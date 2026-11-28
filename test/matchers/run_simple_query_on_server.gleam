//// A matcher that runs a simple query of SQL statements on the driver connection
//// of the chosen version, and goes on with the same sessions.

import dream_postgres/driver/connection/simple_query as connection_simple_query
import dream_postgres/driver/connection/statement as connection_statement
import dream_test/types.{
  type MatchResult, AssertionFailure, CustomMatcherFailure, MatchFailed, MatchOk,
}
import fixtures/executor_sessions.{type ExecutorSessions}
import gleam/option.{Some}
import gleam/result
import gleam/string

/// Run `sql`, one or more statements, as a simple query on the connection of the
/// session of the chosen version. The chain goes on with the same sessions,
/// or fails when the simple query fails.
///
/// ## Example
///
/// ```gleam
/// sessions
/// |> should
/// |> run_simple_query_on_server("CREATE TEMP TABLE counts (id int4)")
/// |> run_on_executor(fn(executor) {
///   runner.affected(query.query("INSERT INTO counts VALUES (1)"), executor, [])
/// })
/// |> be_ok()
/// |> be_equal(1)
/// |> or_fail_with("Expected one row inserted")
/// ```
pub fn run_simple_query_on_server(
  result: MatchResult(ExecutorSessions),
  sql: String,
) -> MatchResult(ExecutorSessions) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(sessions) -> run_on_chosen(sessions, sql)
  }
}

fn run_on_chosen(
  sessions: ExecutorSessions,
  sql: String,
) -> MatchResult(ExecutorSessions) {
  let ran = {
    use session <- result.try(executor_sessions.chosen(sessions))
    connection_simple_query.run_simple_query(
      session.connection,
      connection_statement.statement(sql),
      executor_sessions.deadline_milliseconds,
    )
    |> result.map_error(string.inspect)
  }
  case ran {
    Ok(_outcomes) -> MatchOk(sessions)
    Error(reason) ->
      MatchFailed(AssertionFailure(
        operator: "run_simple_query_on_server",
        message: "",
        payload: Some(CustomMatcherFailure(
          actual: reason,
          description: "expected the simple query to run: " <> sql,
        )),
      ))
  }
}
