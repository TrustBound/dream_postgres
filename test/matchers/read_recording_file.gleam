//// A matcher that reads the file of one recording of the first recorded
//// run of the recorder tests.

import dream_test/types.{
  type MatchResult, AssertionFailure, CustomMatcherFailure, MatchFailed, MatchOk,
}
import fixtures/recorded_scenarios.{type RecordedRuns}
import gleam/option.{Some}
import gleam/string
import simplifile

/// Read the file of the recording `recording` of the first run, as text.
/// The chain goes on with the text, or fails when the file cannot be
/// read.
///
/// ## Example
///
/// ```gleam
/// runs
/// |> should
/// |> read_recording_file("secret")
/// |> not_contain_text("636f727265637420686f727365")
/// |> or_fail_with("Expected no bytes of the password in the file")
/// ```
pub fn read_recording_file(
  result: MatchResult(RecordedRuns),
  recording: String,
) -> MatchResult(String) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(runs) -> read_file(runs, recording)
  }
}

fn read_file(runs: RecordedRuns, recording: String) -> MatchResult(String) {
  case simplifile.read(runs.directory <> "/first/" <> recording <> ".json") {
    Ok(text) -> MatchOk(text)
    Error(reason) ->
      MatchFailed(AssertionFailure(
        operator: "read_recording_file",
        message: "",
        payload: Some(CustomMatcherFailure(
          actual: string.inspect(reason),
          description: "expected the file of " <> recording <> " to be read",
        )),
      ))
  }
}
