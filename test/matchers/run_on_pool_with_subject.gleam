//// A matcher that runs work on a started pool and the subject that came
//// with it, and stops the pool after it.

import dream_postgres/pool.{type Connection}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}

/// Run `work` on the pool and its subject, such as the subject of its
/// notices or of its pool events, then stop the pool. The chain goes on
/// with what `work` gives.
///
/// ## Example
///
/// ```gleam
/// start_with_notices(config)
/// |> should
/// |> be_ok()
/// |> run_on_pool_with_subject(fn(connection, notice_subject) {
///   process.receive(notice_subject, 1000)
/// })
/// |> be_ok()
/// ```
pub fn run_on_pool_with_subject(
  result: MatchResult(#(Connection, subject)),
  work: fn(Connection, subject) -> a,
) -> MatchResult(a) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(#(connection, subject)) -> {
      let outcome = work(connection, subject)
      pool.stop(connection)
      MatchOk(outcome)
    }
  }
}
