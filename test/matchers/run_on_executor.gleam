//// A matcher that runs work on the executor of a driver connection of the
//// chosen version.

import dream_postgres/internal/runner.{type Executor}
import dream_test/types.{type MatchResult}
import fixtures/executor_sessions.{type ExecutorSessions}
import matchers/run_on_executor_with_deadline.{run_on_executor_with_deadline}

/// Run `work` on the executor of the session of the chosen version, with
/// the deadline `executor_sessions.deadline_milliseconds` for each query.
/// The chain goes on with what `work` gives.
///
/// ## Example
///
/// ```gleam
/// sessions
/// |> should
/// |> run_on_executor(fn(executor) {
///   runner.one(query.query("SELECT 42"), single(codec.int), executor, [])
/// })
/// |> be_ok()
/// |> be_equal(42)
/// |> or_fail_with("Expected 42")
/// ```
pub fn run_on_executor(
  result: MatchResult(ExecutorSessions),
  work: fn(Executor) -> a,
) -> MatchResult(a) {
  run_on_executor_with_deadline(
    result,
    executor_sessions.deadline_milliseconds,
    work,
  )
}
