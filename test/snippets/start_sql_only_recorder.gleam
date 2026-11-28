import dream_errors.{type Error}
import dream_postgres/error.{type PostgresError}
import dream_postgres/recorder.{
  type Mode, type Recorder, match_on, mode, new, start,
}
import dream_postgres/recorder/match.{sql_only}

/// A recorder that takes any parameters of the recorded SQL, for a test
/// whose parameters change in each run.
pub fn start_sql_only_recorder(
  recorder_mode: Mode,
) -> Result(Recorder, Error(PostgresError)) {
  new(file: "test/recordings/api_key_list.json")
  |> mode(recorder_mode)
  |> match_on(sql_only)
  |> start
}
