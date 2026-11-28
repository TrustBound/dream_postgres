//// A matcher that runs work on the pool of the chain, then stops the
//// pool.

import dream_postgres/pool.{type Connection}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}

/// Run `work` on the pool, then stop the pool. The chain goes on with
/// what `work` gave.
///
/// ## Example
///
/// ```gleam
/// start_tagged_pool(config)
/// |> should
/// |> be_ok()
/// |> run_and_stop_pool(fn(pool) {
///   query("SELECT 1") |> one(single(codec.int), pool)
/// })
/// |> be_ok()
/// |> be_equal(1)
/// |> or_fail_with("Expected 1")
/// ```
pub fn run_and_stop_pool(
  result: MatchResult(Connection),
  work: fn(Connection) -> a,
) -> MatchResult(a) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(connection) -> {
      let outcome = work(connection)
      pool.stop(connection)
      MatchOk(outcome)
    }
  }
}
