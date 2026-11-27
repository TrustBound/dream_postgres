//// A matcher that runs a script of SQL statements on the driver connection
//// of the chosen version, and goes on with the same sessions.

import dream_postgres/driver/connection
import dream_test/types.{
  type MatchResult, AssertionFailure, CustomMatcherFailure, MatchFailed, MatchOk,
}
import fixtures/executor_sessions.{type ExecutorSessions}
import gleam/option.{Some}
import gleam/result
import gleam/string

/// Run `sql`, one or more statements, as a script on the connection of the
/// session of the chosen version. The chain goes on with the same sessions,
/// or fails when the script fails.
///
/// ## Example
///
/// ```gleam
/// sessions
/// |> should
/// |> run_script_on_server("CREATE TEMP TABLE counts (id int4)")
/// |> run_on_executor(fn(executor) {
///   runner.affected(query.query("INSERT INTO counts VALUES (1)"), executor, [])
/// })
/// |> be_ok()
/// |> be_equal(1)
/// |> or_fail_with("Expected one row inserted")
/// ```
pub fn run_script_on_server(
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
    connection.run_script(
      session.connection,
      connection.statement(sql),
      executor_sessions.deadline_milliseconds,
    )
    |> result.map_error(string.inspect)
  }
  case ran {
    Ok(_outcomes) -> MatchOk(sessions)
    Error(reason) ->
      MatchFailed(AssertionFailure(
        operator: "run_script_on_server",
        message: "",
        payload: Some(CustomMatcherFailure(
          actual: reason,
          description: "expected the script to run: " <> sql,
        )),
      ))
  }
}
