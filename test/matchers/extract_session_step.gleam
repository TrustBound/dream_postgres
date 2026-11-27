//// Runs one query step on a session with a driver server.

import dream_postgres/driver/query.{type Start}
import dream_test/types.{
  type MatchResult, AssertionFailure, CustomMatcherFailure, MatchFailed, MatchOk,
}
import driver/server_query.{type Session, type StepFunction, run_step}
import gleam/option.{Some}
import gleam/string.{inspect}

/// Sends the messages of `start`, gives each answer of the server to
/// `step` until it finishes, and gives the outcome and the session after
/// it. Fails when the step does not finish: a transport, decode or login
/// failure, a refused message, or a server that ended the connection.
///
/// ```gleam
/// open_session(server)
/// |> should
/// |> be_ok
/// |> extract_session_step(start_simple_query("SELECT 1"), step_simple_query)
/// |> extract_step_outcome
/// |> extract_outcome_result
/// |> be_ok
/// |> extract_statement_tags
/// |> be_equal([#("SELECT 1", 1)])
/// |> or_fail_with("Expected SELECT 1")
/// ```
pub fn extract_session_step(
  result: MatchResult(Session),
  start: Start(state),
  step: StepFunction(state, outcome),
) -> MatchResult(#(outcome, Session)) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(session) -> finished(run_step(session, start, step))
  }
}

fn finished(
  stepped: Result(#(outcome, Session), server_query.QueryFailure),
) -> MatchResult(#(outcome, Session)) {
  case stepped {
    Ok(outcome_and_session) -> MatchOk(outcome_and_session)
    Error(failure) ->
      MatchFailed(AssertionFailure(
        operator: "extract_session_step",
        message: "",
        payload: Some(CustomMatcherFailure(
          actual: inspect(failure),
          description: "Expected the query step to finish",
        )),
      ))
  }
}
