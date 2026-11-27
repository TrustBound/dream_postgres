//// Runs a started login through the messages of a server.

import dream_postgres/driver/login.{
  type LoginError, type LoginOutcome, type LoginState, type LoginStep, Continue,
  LoggedIn, step,
}
import dream_postgres/driver/message.{type BackendMessage, type FrontendMessage}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}
import gleam/list.{reverse}
import gleam/option.{type Option, None, Some}
import gleam/result.{try}

/// What a login gave: each reply in order, and the outcome if it ended.
pub type LoginRun {
  LoginRun(replies: List(FrontendMessage), outcome: Option(LoginOutcome))
}

/// Takes the result of `start`, and gives each message to `step` in turn.
/// Gives the replies and the outcome, or the first error of `start` or
/// `step`. The run stops when the login ends or the messages end.
///
/// ```gleam
/// started
/// |> should
/// |> extract_login_run([AuthenticationOk, ReadyForQuery(Idle)])
/// |> be_ok
/// |> be_equal(LoginRun([], Some(outcome)))
/// |> or_fail_with("Expected a login with no password")
/// ```
pub fn extract_login_run(
  result: MatchResult(Result(#(LoginState, FrontendMessage), LoginError)),
  messages: List(BackendMessage),
) -> MatchResult(Result(LoginRun, LoginError)) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(started) -> MatchOk(try(started, run(_, messages)))
  }
}

fn run(
  started: #(LoginState, FrontendMessage),
  messages: List(BackendMessage),
) -> Result(LoginRun, LoginError) {
  run_messages(started.0, messages, [])
}

fn run_messages(
  state: LoginState,
  messages: List(BackendMessage),
  replies: List(FrontendMessage),
) -> Result(LoginRun, LoginError) {
  case messages {
    [] -> Ok(LoginRun(reverse(replies), None))
    [message, ..rest] ->
      step(state, message) |> try(next_step(_, rest, replies))
  }
}

fn next_step(
  login_step: LoginStep,
  rest: List(BackendMessage),
  replies: List(FrontendMessage),
) -> Result(LoginRun, LoginError) {
  case login_step {
    Continue(state:, reply:) ->
      run_messages(state, rest, add_reply(replies, reply))
    LoggedIn(outcome:) -> Ok(LoginRun(reverse(replies), Some(outcome)))
  }
}

fn add_reply(
  replies: List(FrontendMessage),
  reply: Option(FrontendMessage),
) -> List(FrontendMessage) {
  case reply {
    Some(message) -> [message, ..replies]
    None -> replies
  }
}
