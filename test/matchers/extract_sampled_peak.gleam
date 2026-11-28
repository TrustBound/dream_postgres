//// Pairs the count of a COPY with the memory peak that its produce
//// function sampled.

import dream_test/types.{
  type MatchResult, AssertionFailure, CustomMatcherFailure, MatchFailed, MatchOk,
}
import fixtures/copy_callbacks.{type MemoryPeak}
import gleam/erlang/process.{type Subject}
import gleam/option.{Some}

/// Gives the count with the peak that `load_chunks_sampling` sent to
/// `peaks`. Fails when no peak waits there.
///
/// ```gleam
/// copy_from(connection, "COPY loaded FROM STDIN", 5000, load_chunks_sampling(_, pid, peaks))
/// |> should
/// |> be_ok
/// |> extract_sampled_peak(from: peaks)
/// |> within_memory(2_000_000, 0)
/// |> be_equal(1_000_000)
/// |> or_fail_with("Expected 1,000,000 rows stored")
/// ```
pub fn extract_sampled_peak(
  result: MatchResult(Int),
  from peaks: Subject(MemoryPeak),
) -> MatchResult(#(Int, MemoryPeak)) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(count) -> paired_with_peak(count, process.receive(peaks, 0))
  }
}

fn paired_with_peak(
  count: Int,
  received: Result(MemoryPeak, Nil),
) -> MatchResult(#(Int, MemoryPeak)) {
  case received {
    Ok(peak) -> MatchOk(#(count, peak))
    Error(Nil) ->
      MatchFailed(AssertionFailure(
        operator: "extract_sampled_peak",
        message: "",
        payload: Some(CustomMatcherFailure(
          actual: "no peak",
          description: "Expected the produce function to send its peak",
        )),
      ))
  }
}
