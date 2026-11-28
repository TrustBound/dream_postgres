//// A matcher that runs work while the supervisor of the chain runs, then
//// stops the supervisor and its children.

import dream_test/types.{type MatchResult, MatchFailed, MatchOk}
import fixtures/supervisors
import gleam/otp/actor.{type Started}
import gleam/otp/static_supervisor.{type Supervisor}

/// Run `work`, then stop the supervisor and wait until it is gone. The
/// chain goes on with what `work` gave.
///
/// ## Example
///
/// ```gleam
/// start_database_supervisor(config, database)
/// |> should
/// |> be_ok()
/// |> run_and_stop_supervisor(fn() {
///   query("SELECT 1") |> one(single(codec.int), named_connection(database))
/// })
/// |> be_ok()
/// |> be_equal(1)
/// |> or_fail_with("Expected 1")
/// ```
pub fn run_and_stop_supervisor(
  result: MatchResult(Started(Supervisor)),
  work: fn() -> a,
) -> MatchResult(a) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(started) -> {
      let outcome = work()
      supervisors.stop_supervisor(started.pid)
      MatchOk(outcome)
    }
  }
}
