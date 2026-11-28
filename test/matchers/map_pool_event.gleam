//// A matcher that maps a pool event of the driver to the pool event of the client.

import dream_postgres/config.{type PoolEvent}
import dream_postgres/driver/pool/pool_event
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}

/// Map a pool event of the driver to the pool event of the client. The chain goes on with the result.
///
/// ## Example
///
/// ```gleam
/// pool_event.MemberHeld(slot: 2)
/// |> should
/// |> map_pool_event("db", 5432)
/// |> be_equal(Held(slot: 2))
/// |> or_fail_with("Expected Held(2)")
/// ```
pub fn map_pool_event(
  result: MatchResult(pool_event.PoolEvent),
  host: String,
  port: Int,
) -> MatchResult(PoolEvent) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(value) -> MatchOk(config.pool_event(value, host, port))
  }
}
