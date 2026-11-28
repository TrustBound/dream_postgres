//// A matcher that receives the next message of a subject, after the work
//// of the chain.

import dream_test/types.{
  type MatchResult, AssertionFailure, CustomMatcherFailure, MatchFailed, MatchOk,
}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/option.{Some}

/// Receive the next message of `subject` within `milliseconds`. The chain
/// goes on with the message, or fails when none came in time.
///
/// ## Example
///
/// ```gleam
/// pools
/// |> should
/// |> run_on_pool(fn(connection) {
///   query("SELECT 1") |> affected(with_interceptor(connection, send_tags_to(seen)))
/// })
/// |> receive_message(seen, within: 1000)
/// |> be_equal(Ok("SELECT 1"))
/// |> or_fail_with("Expected the watcher to see SELECT 1")
/// ```
pub fn receive_message(
  result: MatchResult(a),
  subject: Subject(message),
  within milliseconds: Int,
) -> MatchResult(message) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(_work_result) -> receive_within(subject, milliseconds)
  }
}

fn receive_within(
  subject: Subject(message),
  milliseconds: Int,
) -> MatchResult(message) {
  case process.receive(subject, milliseconds) {
    Ok(message) -> MatchOk(message)
    Error(Nil) ->
      MatchFailed(AssertionFailure(
        operator: "receive_message",
        message: "",
        payload: Some(CustomMatcherFailure(
          actual: "no message",
          description: "expected a message within "
            <> int.to_string(milliseconds)
            <> " milliseconds",
        )),
      ))
  }
}
