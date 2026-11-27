//// A matcher that runs work on the executor of a driver connection of the
//// chosen version, with a deadline for each query.

import dream_postgres/internal/driver_executor
import dream_postgres/internal/runner.{type Executor}
import dream_postgres/secrets
import dream_test/types.{
  type MatchResult, AssertionFailure, CustomMatcherFailure, MatchFailed, MatchOk,
}
import fixtures/endpoints
import fixtures/executor_sessions.{type ExecutorSessions}
import gleam/option.{Some}

/// Run `work` on the executor of the session of the chosen version, with a
/// deadline of `deadline_milliseconds` for each query. The chain goes on
/// with what `work` gives.
///
/// ## Example
///
/// ```gleam
/// sessions
/// |> should
/// |> run_on_executor_with_deadline(1, fn(executor) {
///   runner.affected(query.query("SELECT pg_sleep(1)"), executor, [])
/// })
/// |> be_error()
/// |> have_cause()
/// |> have_reason()
/// |> be_equal(error.QueryTimeout(stopped_on_server: True))
/// |> or_fail_with("Expected QueryTimeout")
/// ```
pub fn run_on_executor_with_deadline(
  result: MatchResult(ExecutorSessions),
  deadline_milliseconds: Int,
  work: fn(Executor) -> a,
) -> MatchResult(a) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(sessions) -> run_on_chosen(sessions, deadline_milliseconds, work)
  }
}

fn run_on_chosen(
  sessions: ExecutorSessions,
  deadline_milliseconds: Int,
  work: fn(Executor) -> a,
) -> MatchResult(a) {
  case executor_sessions.chosen(sessions) {
    Ok(session) ->
      driver_executor.executor(
        session.connection,
        session.catalog,
        endpoints.example_endpoint(),
        secrets.new(),
        deadline_milliseconds,
      )
      |> work
      |> MatchOk
    Error(reason) ->
      MatchFailed(AssertionFailure(
        operator: "run_on_executor",
        message: "",
        payload: Some(CustomMatcherFailure(
          actual: reason,
          description: "expected an executor session of the chosen version",
        )),
      ))
  }
}
