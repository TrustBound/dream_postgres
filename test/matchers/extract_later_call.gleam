//// Extracts the later call of a crashed map from the run of a pool whose
//// connection was replaced.

import dream_test/types.{type MatchResult, MatchFailed, MatchOk}
import driver/server_sink.{type ReplacedRun}

/// Gives the next call of the crashed map after its first one:
/// `Error(Nil)` when the driver did not call it again.
///
/// ```gleam
/// raise_across_replacement(port, sinks, witness, raise_notice)
/// |> should
/// |> be_ok
/// |> extract_later_call
/// |> be_error
/// |> or_fail_with("Expected no call of the map after its crash")
/// ```
pub fn extract_later_call(
  result: MatchResult(ReplacedRun(called)),
) -> MatchResult(Result(called, Nil)) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(run) -> MatchOk(run.later_call)
  }
}
