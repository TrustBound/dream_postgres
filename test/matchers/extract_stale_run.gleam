//// Extracts the answer of the run after a prepare from the cache after a
//// schema change.

import dream_postgres/driver/connection/outcome.{type Outcome}
import dream_postgres/driver/connection/request_failure.{type RunError}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}
import driver/server_prepare.{type StaleOutcome}

/// Gives the answer of the run.
///
/// ```gleam
/// prepare_and_run_after_change(port, "ALTER TABLE t DROP COLUMN c")
/// |> should
/// |> be_ok
/// |> extract_stale_run
/// |> be_error
/// |> extract_changed_column_names
/// |> be_equal(["a", "b"])
/// |> or_fail_with("Expected RunStatementChanged")
/// ```
pub fn extract_stale_run(
  result: MatchResult(StaleOutcome),
) -> MatchResult(Result(Outcome, RunError)) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(outcome) -> MatchOk(outcome.ran)
  }
}
