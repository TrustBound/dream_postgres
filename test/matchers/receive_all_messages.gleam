//// A matcher that collects every message that a subject gets, until no
//// message comes for a while.

import dream_test/types.{type MatchResult, MatchFailed, MatchOk}
import gleam/erlang/process.{type Subject}
import gleam/list

/// After the work of the chain, collect each message of `subject` in the
/// order they came, until none comes for `milliseconds`. The chain goes
/// on with the messages, which can be none.
///
/// ## Example
///
/// ```gleam
/// config
/// |> dream_postgres.pool_events(events)
/// |> should
/// |> run_on_started_pool(fn(connection) {
///   query("SELECT 1") |> all(single(codec.int), connection)
/// })
/// |> receive_all_messages(events, within: 100)
/// |> contain(Held(slot: 0))
/// |> or_fail_with("Expected Held(0)")
/// ```
pub fn receive_all_messages(
  result: MatchResult(a),
  subject: Subject(message),
  within milliseconds: Int,
) -> MatchResult(List(message)) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(_work_result) -> MatchOk(collect(subject, milliseconds, []))
  }
}

fn collect(
  subject: Subject(message),
  milliseconds: Int,
  collected: List(message),
) -> List(message) {
  case process.receive(subject, milliseconds) {
    Ok(message) -> collect(subject, milliseconds, [message, ..collected])
    Error(Nil) -> list.reverse(collected)
  }
}
