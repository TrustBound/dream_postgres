//// A matcher that runs work on the client pool of the chosen version.

import dream_postgres/pool.{type Connection}
import dream_test/types.{
  type MatchResult, AssertionFailure, CustomMatcherFailure, MatchFailed, MatchOk,
}
import fixtures/server_pools.{type ServerPools}
import gleam/option.{Some}

/// Run `work` on the pool of the chosen version. The chain goes on with
/// what `work` gives.
///
/// ## Example
///
/// ```gleam
/// pools
/// |> should
/// |> run_on_pool(fn(connection) {
///   query("SELECT 7") |> one(single(codec.int), connection)
/// })
/// |> be_ok()
/// |> be_equal(7)
/// |> or_fail_with("Expected 7")
/// ```
pub fn run_on_pool(
  result: MatchResult(ServerPools),
  work: fn(Connection) -> a,
) -> MatchResult(a) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(pools) -> run_on_chosen(pools, work)
  }
}

fn run_on_chosen(
  pools: ServerPools,
  work: fn(Connection) -> a,
) -> MatchResult(a) {
  case server_pools.chosen(pools) {
    Ok(pool) -> MatchOk(work(pool.connection))
    Error(reason) ->
      MatchFailed(AssertionFailure(
        operator: "run_on_pool",
        message: "",
        payload: Some(CustomMatcherFailure(
          actual: reason,
          description: "expected a pool of the chosen version",
        )),
      ))
  }
}
