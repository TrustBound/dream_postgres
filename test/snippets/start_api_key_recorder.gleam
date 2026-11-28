import dream_errors.{type Error}
import dream_postgres/error.{type PostgresError}
import dream_postgres/recorder.{
  type Mode, type Recorder, intercept, match_on, mode, new, start,
}
import dream_postgres/recorder/match.{sql_and_parameters}
import dream_postgres/recorder/normalize.{generated_uuids, timestamps_near_now}

/// Starts the recorder of the test that creates an API key. The test
/// gives the mode, which it reads from its own config.
pub fn start_api_key_recorder(
  recorder_mode: Mode,
) -> Result(Recorder, Error(PostgresError)) {
  new(file: "test/recordings/api_key_create.json")
  |> mode(recorder_mode)
  |> match_on(sql_and_parameters)
  |> intercept(generated_uuids(keep: []))
  |> intercept(timestamps_near_now(window_days: 400))
  |> start
}
