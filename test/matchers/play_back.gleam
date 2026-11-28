//// A matcher that plays back one recording of the recorder tests on a
//// connection with no database, and gives what the code under test gave.

import dream_postgres/config
import dream_postgres/pool.{type Connection}
import dream_postgres/recorder
import dream_test/types.{
  type MatchResult, AssertionFailure, CustomMatcherFailure, MatchFailed, MatchOk,
}
import fixtures/recorded_scenarios.{type RecordedRuns, type ScenarioResult}
import fixtures/server_pools
import gleam/option.{Some}
import gleam/result
import gleam/string

/// Start a recorder in playback mode on the recording `recording` of the
/// first recorded run, with the settings of its scenario, connect with a
/// config whose port has no server, run `scenario` on the connection, and
/// stop the connection with its recorder. The chain goes on with what the
/// scenario gave, or fails when the recorder or the connection does not
/// start.
///
/// ## Example
///
/// ```gleam
/// runs
/// |> should
/// |> play_back("all", recorded_scenarios.select_series)
/// |> be_ok()
/// |> be_equal("[1, 2, 3]")
/// |> or_fail_with("Expected the recorded rows")
/// ```
pub fn play_back(
  result: MatchResult(RecordedRuns),
  recording: String,
  scenario: fn(Connection) -> ScenarioResult,
) -> MatchResult(ScenarioResult) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(runs) -> play_back_runs(runs, recording, scenario)
  }
}

fn play_back_runs(
  runs: RecordedRuns,
  recording: String,
  scenario: fn(Connection) -> ScenarioResult,
) -> MatchResult(ScenarioResult) {
  let settings = recorded_scenarios.scenario_of(recording)
  let played = {
    use path <- result.try(recorded_scenarios.copy_of(runs, recording))
    use test_recorder <- result.try(
      recorder.new(file: path)
      |> recorder.mode(recorder.Playback)
      |> settings.recorder_settings
      |> recorder.start
      |> result.map_error(string.inspect),
    )
    use connection <- result.try(
      server_pools.config(recorded_scenarios.closed_port)
      |> settings.app_settings
      |> config.record(test_recorder)
      |> pool.start
      |> result.map_error(string.inspect),
    )
    let ran = scenario(connection)
    pool.stop(connection)
    Ok(ran)
  }
  case played {
    Ok(found) -> MatchOk(found)
    Error(reason) ->
      MatchFailed(AssertionFailure(
        operator: "play_back",
        message: "",
        payload: Some(CustomMatcherFailure(
          actual: reason,
          description: "expected the recording " <> recording <> " to play back",
        )),
      ))
  }
}
