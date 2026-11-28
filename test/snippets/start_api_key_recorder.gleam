import dream_errors.{type Error}
import dream_postgres/error.{type PostgresError}
import dream_postgres/normalize.{generated_uuids, timestamps_near_now}
import dream_postgres/recorder.{
  type Mode, type Recorder, intercept, match_on, mode, recorder,
  sql_and_parameters, start_recorder,
}

/// Starts the recorder of the test that creates an API key. The test
/// gives the mode, which it reads from its own config.
pub fn start_api_key_recorder(
  recorder_mode: Mode,
) -> Result(Recorder, Error(PostgresError)) {
  recorder(file: "test/recordings/api_key_create.json")
  |> mode(recorder_mode)
  |> match_on(sql_and_parameters)
  |> intercept(generated_uuids(keep: []))
  |> intercept(timestamps_near_now(window_days: 400))
  |> start_recorder
}
