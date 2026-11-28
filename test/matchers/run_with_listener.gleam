//// A matcher that starts a listener on the server of the chosen version,
//// runs work with it and the pool of that server, and stops it.

import dream_postgres/error
import dream_postgres/listener.{type Listener}
import dream_postgres/pool.{type Connection}
import dream_test/types.{
  type MatchResult, AssertionFailure, CustomMatcherFailure, MatchFailed, MatchOk,
}
import fixtures/server_pools.{type ServerPools}
import gleam/option.{Some}
import gleam/result

/// Start a listener with the config of the client tests on the server of
/// the chosen version, run `work` with the listener and the pool of that
/// server, and stop the listener. The chain goes on with what `work`
/// gives, or fails when the listener cannot start.
///
/// ## Example
///
/// ```gleam
/// pools
/// |> should
/// |> run_with_listener(fn(listener, connection) {
///   use _subscription <- result.try(listen(listener, "jobs", messages))
///   run_sql("NOTIFY jobs, 'hello'", connection)
/// })
/// |> receive_message(messages, within: 5000)
/// |> extract_listen_payload()
/// |> be_equal(#("jobs", "hello"))
/// |> or_fail_with("Expected the notification")
/// ```
pub fn run_with_listener(
  result: MatchResult(ServerPools),
  work: fn(Listener, Connection) -> a,
) -> MatchResult(a) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(pools) -> run_on_chosen(pools, work)
  }
}

fn run_on_chosen(
  pools: ServerPools,
  work: fn(Listener, Connection) -> a,
) -> MatchResult(a) {
  let started = {
    use pool <- result.try(server_pools.chosen(pools))
    server_pools.config(pool.port)
    |> listener.start_listener
    |> result.map(fn(listener) { #(listener, pool.connection) })
    |> result.map_error(error.describe_error)
  }
  case started {
    Ok(#(listener, connection)) -> {
      let outcome = work(listener, connection)
      listener.stop_listener(listener)
      MatchOk(outcome)
    }
    Error(reason) ->
      MatchFailed(AssertionFailure(
        operator: "run_with_listener",
        message: "",
        payload: Some(CustomMatcherFailure(
          actual: reason,
          description: "expected the listener to start",
        )),
      ))
  }
}
