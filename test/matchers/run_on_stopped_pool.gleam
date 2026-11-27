//// A matcher that runs work on a pool of the chosen server after the pool
//// stopped.

import dream_postgres.{type Connection}
import dream_postgres/error
import dream_test/types.{
  type MatchResult, AssertionFailure, CustomMatcherFailure, MatchFailed, MatchOk,
}
import fixtures/server_pools.{type ServerPools}
import gleam/option.{Some}
import gleam/result

/// Start a new pool of one connection on the server of the chosen version,
/// stop it, and run `work` on the stopped pool. The chain goes on with
/// what `work` gives, or fails when the pool cannot start.
///
/// ## Example
///
/// ```gleam
/// pools
/// |> should
/// |> run_on_stopped_pool(fn(connection) { script("SELECT 1", connection) })
/// |> be_error()
/// |> summarise_error()
/// |> be_equal("unavailable PoolStopped")
/// |> or_fail_with("Expected the stopped pool to be unavailable")
/// ```
pub fn run_on_stopped_pool(
  result: MatchResult(ServerPools),
  work: fn(Connection) -> a,
) -> MatchResult(a) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(pools) -> run_on_new_pool(pools, work)
  }
}

fn run_on_new_pool(
  pools: ServerPools,
  work: fn(Connection) -> a,
) -> MatchResult(a) {
  let started = {
    use pool <- result.try(server_pools.chosen(pools))
    server_pools.config(pool.port)
    |> dream_postgres.pool_size(1)
    |> dream_postgres.start
    |> result.map_error(error.describe)
  }
  case started {
    Ok(connection) -> {
      dream_postgres.stop(connection)
      MatchOk(work(connection))
    }
    Error(reason) ->
      MatchFailed(AssertionFailure(
        operator: "run_on_stopped_pool",
        message: "",
        payload: Some(CustomMatcherFailure(
          actual: reason,
          description: "expected a new pool to start",
        )),
      ))
  }
}
