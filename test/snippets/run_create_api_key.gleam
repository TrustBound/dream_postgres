import dream_errors.{type Error}
import dream_postgres/config.{type Config, record}
import dream_postgres/error.{type PostgresError}
import dream_postgres/pool.{start_pool, stop_pool}
import dream_postgres/recorder.{type Recorder}
import gleam/result
import snippets/app_config.{app_config}
import snippets/create_api_key.{type ApiKey, create_api_key}
import snippets/with_api_keys_table.{with_api_keys_table}

/// One run of the test: in `Record` mode on the database of the app
/// config, in `Playback` mode on the recording alone.
pub fn run_create_api_key(
  server: Config,
  test_recorder: Recorder,
  owner: Int,
) -> Result(ApiKey, Error(PostgresError)) {
  use connection <- result.try(
    app_config(server)
    |> record(test_recorder)
    |> start_pool,
  )
  let created =
    with_api_keys_table(connection, create_api_key(_, owner, "s3cret"))
  stop_pool(connection)
  created
}
