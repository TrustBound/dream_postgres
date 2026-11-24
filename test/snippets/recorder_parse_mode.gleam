import dream_postgres/recorder
import gleam/result

pub fn start_from_text(
  mode_text: String,
  directory: String,
  test_name: String,
) -> Result(recorder.Recorder, String) {
  use mode <- result.try(recorder.parse_mode(mode_text))
  recorder.new()
  |> recorder.directory(directory)
  |> recorder.name(test_name)
  |> recorder.mode(mode)
  |> recorder.start()
}
