//// Extracts the answers of both connections from the run of a pool whose
//// connection was replaced.

import dream_test/types.{type MatchResult, MatchFailed, MatchOk}
import driver/server_sink.{type ReplacedRun}

/// Gives the answers of the two connections of the pool after the
/// replacement: the new connection and the other one.
///
/// ```gleam
/// raise_across_replacement(port, sinks, witness, raise_notice)
/// |> should
/// |> be_ok
/// |> extract_replaced_answers
/// |> be_equal(#("answered", "answered"))
/// |> or_fail_with("Expected both connections to answer")
/// ```
pub fn extract_replaced_answers(
  result: MatchResult(ReplacedRun(called)),
) -> MatchResult(#(String, String)) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(run) -> MatchOk(run.answers)
  }
}
