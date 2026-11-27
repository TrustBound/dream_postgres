//// A matcher that reads the two recordings of one scenario that the
//// recorder tests recorded in two runs.

import dream_test/types.{
  type MatchResult, AssertionFailure, CustomMatcherFailure, MatchFailed, MatchOk,
}
import fixtures/recorded_scenarios.{type RecordedRuns}
import gleam/option.{Some}
import gleam/result
import gleam/string
import simplifile

/// Read the file of the recording `recording` of the first run and of the
/// second run, as bytes. The chain goes on with the pair, or fails when a
/// file cannot be read.
///
/// ## Example
///
/// ```gleam
/// runs
/// |> should
/// |> read_recording_pair("identical")
/// |> be_equal_parts
/// |> or_fail_with("Expected the same bytes in both runs")
/// ```
pub fn read_recording_pair(
  result: MatchResult(RecordedRuns),
  recording: String,
) -> MatchResult(#(BitArray, BitArray)) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(runs) -> read_pair(runs, recording)
  }
}

fn read_pair(
  runs: RecordedRuns,
  recording: String,
) -> MatchResult(#(BitArray, BitArray)) {
  let read = {
    use first <- result.try(simplifile.read_bits(
      runs.directory <> "/first/" <> recording <> ".json",
    ))
    use second <- result.try(simplifile.read_bits(
      runs.directory <> "/second/" <> recording <> ".json",
    ))
    Ok(#(first, second))
  }
  case read {
    Ok(pair) -> MatchOk(pair)
    Error(reason) ->
      MatchFailed(AssertionFailure(
        operator: "read_recording_pair",
        message: "",
        payload: Some(CustomMatcherFailure(
          actual: string.inspect(reason),
          description: "expected both files of " <> recording <> " to be read",
        )),
      ))
  }
}
