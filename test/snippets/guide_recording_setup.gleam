//// Recorded queries guide: start a recorder and connect
////
//// One recording file for each test, in one directory. The mode is text,
//// so a test run can take it from an environment variable.

import dream_pog as pog
import dream_postgres/client as postgres
import dream_postgres/recorder
import gleam/erlang/process
import gleam/result
import gleam/string

pub fn start_recorder(
  mode: recorder.Mode,
  directory: String,
  test_name: String,
) -> Result(recorder.Recorder, String) {
  recorder.new()
  |> recorder.directory(directory)
  |> recorder.name(test_name)
  |> recorder.mode(mode)
  |> recorder.start()
}

/// In playback mode, nothing connects to `database_url`.
pub fn connect(
  recording: recorder.Recorder,
  database_url: String,
) -> Result(pog.Connection, String) {
  use config <- result.try(
    postgres.parse_config(process.new_name("test_database"), database_url)
    |> result.map_error(string.inspect),
  )
  recorder.connect(recording, config)
  |> result.map_error(string.inspect)
}
