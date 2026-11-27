//// Gives a login state to the login steps, and extracts the state after.

import dream_postgres/driver/login.{
  type LoginError, type LoginState, type LoginStep, Continue, LoggedIn, step,
}
import dream_postgres/driver/message.{type BackendMessage}
import dream_test/types.{
  type MatchResult, AssertionFailure, CustomMatcherFailure, MatchFailed, MatchOk,
}
import gleam/option.{Some}
import gleam/string.{inspect}

/// Gives each message to `step` in turn, and gives the login state after
/// the last one. Fails when a step gives an error, or when the login ends
/// before the messages do.
///
/// ```gleam
/// state
/// |> should
/// |> extract_state_after([AuthenticationSasl(["SCRAM-SHA-256"])])
/// |> extract_printed
/// |> not_contain_text("pencil")
/// |> or_fail_with("Expected no password text")
/// ```
pub fn extract_state_after(
  result: MatchResult(LoginState),
  messages: List(BackendMessage),
) -> MatchResult(LoginState) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(state) -> state_after(state, messages)
  }
}

fn state_after(
  state: LoginState,
  messages: List(BackendMessage),
) -> MatchResult(LoginState) {
  case messages {
    [] -> MatchOk(state)
    [message, ..rest] -> next_state(step(state, message), rest)
  }
}

fn next_state(
  stepped: Result(LoginStep, LoginError),
  rest: List(BackendMessage),
) -> MatchResult(LoginState) {
  case stepped {
    Ok(Continue(state:, reply: _)) -> state_after(state, rest)
    Ok(LoggedIn(outcome:)) ->
      failure(inspect(outcome), "Expected the login to go on, not to end")
    Error(error) -> failure(inspect(error), "Expected each step to work")
  }
}

fn failure(actual: String, description: String) -> MatchResult(LoginState) {
  MatchFailed(AssertionFailure(
    operator: "extract_state_after",
    message: "",
    payload: Some(CustomMatcherFailure(actual:, description:)),
  ))
}
