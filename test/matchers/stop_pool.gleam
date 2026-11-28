//// A matcher that stops the pool of the chain.

import dream_postgres/pool.{type Connection}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}

/// Stop the pool. The chain goes on with `Nil`.
///
/// ## Example
///
/// ```gleam
/// start_pool_on("localhost")
/// |> should
/// |> be_ok()
/// |> stop_pool()
/// |> be_equal(Nil)
/// |> or_fail_with("Expected the pool to start")
/// ```
pub fn stop_pool(result: MatchResult(Connection)) -> MatchResult(Nil) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(connection) -> MatchOk(pool.stop(connection))
  }
}
