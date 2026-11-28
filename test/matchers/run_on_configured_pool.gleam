//// A matcher that starts a pool on the server of the chosen version with
//// a changed config, runs work on it, and stops it.

import dream_postgres/config.{type Config}
import dream_postgres/pool.{type Connection}
import dream_test/types.{
  type MatchResult, AssertionFailure, CustomMatcherFailure, MatchFailed, MatchOk,
}
import fixtures/server_pools.{type ServerPools}
import gleam/option.{Some}
import matchers/run_on_started_pool.{run_on_started_pool}

/// Start a pool on the server of the chosen version, with the config of
/// the client tests that `configure` changed, run `work` on it, and stop
/// the pool. The chain goes on with what `work` gives.
///
/// ## Example
///
/// ```gleam
/// pools
/// |> should
/// |> run_on_configured_pool(pool_size(_, 1), fn(connection) {
///   query("SELECT 1") |> one(single(codec.int), connection)
/// })
/// |> be_ok()
/// |> be_equal(1)
/// |> or_fail_with("Expected 1")
/// ```
pub fn run_on_configured_pool(
  result: MatchResult(ServerPools),
  configure: fn(Config) -> Config,
  work: fn(Connection) -> a,
) -> MatchResult(a) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(pools) -> run_on_chosen(pools, configure, work)
  }
}

fn run_on_chosen(
  pools: ServerPools,
  configure: fn(Config) -> Config,
  work: fn(Connection) -> a,
) -> MatchResult(a) {
  case server_pools.chosen(pools) {
    Ok(pool) ->
      configure(server_pools.config(pool.port))
      |> MatchOk
      |> run_on_started_pool(work)
    Error(reason) ->
      MatchFailed(AssertionFailure(
        operator: "run_on_configured_pool",
        message: "",
        payload: Some(CustomMatcherFailure(
          actual: reason,
          description: "expected a pool of the chosen version",
        )),
      ))
  }
}
