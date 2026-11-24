//// Recorder: match the SQL with its whitespace made the same
////
//// A query whose line breaks or indentation changed still matches its
//// recording.

import dream_postgres/recorder

pub fn playback_ignoring_whitespace(
  directory: String,
  test_name: String,
) -> Result(recorder.Recorder, String) {
  recorder.new()
  |> recorder.directory(directory)
  |> recorder.name(test_name)
  |> recorder.mode("playback")
  |> recorder.key(recorder.normalized_sql_and_parameters)
  |> recorder.start()
}
