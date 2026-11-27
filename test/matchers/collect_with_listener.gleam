//// A matcher that starts a listener on the server of the chosen version,
//// runs work with it and the pool of that server, collects the messages
//// of a subject while the listener runs, and stops it.

import dream_errors.{type Error}
import dream_postgres.{type Connection, type Listener}
import dream_postgres/error.{type PostgresError}
import dream_test/types.{
  type MatchResult, AssertionFailure, CustomMatcherFailure, MatchFailed, MatchOk,
}
import fixtures/server_pools.{type ServerPools}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{Some}
import gleam/result

/// Start a listener with the config of the client tests on the server of
/// the chosen version, and run `work` with the listener and the pool of
/// that server. Then collect each message of `subject` until none comes
/// for `milliseconds`, and stop the listener. The chain goes on with the
/// messages, or fails when the listener cannot start or `work` fails.
///
/// ## Example
///
/// ```gleam
/// pools
/// |> should
/// |> collect_with_listener(messages, within: 500, work: fn(listener, connection) {
///   use _subscription <- result.try(listen(listener, "jobs", messages))
///   script("NOTIFY jobs, 'hello'", connection)
/// })
/// |> extract_listen_payloads()
/// |> be_equal([#("jobs", "hello")])
/// |> or_fail_with("Expected the notification")
/// ```
pub fn collect_with_listener(
  result: MatchResult(ServerPools),
  subject: Subject(message),
  within milliseconds: Int,
  work work: fn(Listener, Connection) -> Result(a, Error(PostgresError)),
) -> MatchResult(List(message)) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(pools) -> collect_on_chosen(pools, subject, milliseconds, work)
  }
}

fn collect_on_chosen(
  pools: ServerPools,
  subject: Subject(message),
  milliseconds: Int,
  work: fn(Listener, Connection) -> Result(a, Error(PostgresError)),
) -> MatchResult(List(message)) {
  let collected = {
    use pool <- result.try(server_pools.chosen(pools))
    use listener <- result.try(
      server_pools.config(pool.port)
      |> dream_postgres.start_listener
      |> result.map_error(error.describe),
    )
    let worked =
      work(listener, pool.connection) |> result.map_error(error.describe)
    let messages = collect(subject, milliseconds, [])
    dream_postgres.stop_listener(listener)
    result.replace(worked, messages)
  }
  case collected {
    Ok(messages) -> MatchOk(messages)
    Error(reason) ->
      MatchFailed(AssertionFailure(
        operator: "collect_with_listener",
        message: "",
        payload: Some(CustomMatcherFailure(
          actual: reason,
          description: "expected the listener to start and the work to succeed",
        )),
      ))
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
