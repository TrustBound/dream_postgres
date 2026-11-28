//// Extracts the description that a prepare from the cache gave after a
//// schema change.

import dream_postgres/driver/cell.{type StatementDescription}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}
import driver/server_prepare.{type StaleOutcome}

/// Gives the description of the prepare.
///
/// ```gleam
/// prepare_and_run_after_change(port, "ALTER TABLE t DROP COLUMN c")
/// |> should
/// |> be_ok
/// |> extract_stale_prepared
/// |> extract_description_columns
/// |> extract_column_names
/// |> be_equal(["a", "b", "c"])
/// |> or_fail_with("Expected the cached columns")
/// ```
pub fn extract_stale_prepared(
  result: MatchResult(StaleOutcome),
) -> MatchResult(StatementDescription) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(outcome) -> MatchOk(outcome.prepared)
  }
}
