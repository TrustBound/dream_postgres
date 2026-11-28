import dream_postgres/config.{type Config, record}
import dream_postgres/error.{describe_error}
import dream_postgres/pool.{type PoolName, supervised}
import dream_postgres/recorder.{type Recorder}
import gleam/otp/actor
import gleam/otp/static_supervisor.{type Supervisor}
import gleam/result
import snippets/app_config.{app_config}

/// Starts the app's supervisor with the pool of the app config under
/// `pool_name`. With a recorder in `Playback` mode, the pool has no
/// database, and `named_connection(pool_name)` answers from the recording.
pub fn start_app_supervisor(
  server: Config,
  test_recorder: Recorder,
  pool_name: PoolName,
) -> Result(actor.Started(Supervisor), String) {
  use pool_child <- result.try(
    app_config(server)
    |> record(test_recorder)
    |> supervised(name: pool_name)
    |> result.map_error(describe_error),
  )
  static_supervisor.new(static_supervisor.OneForOne)
  |> static_supervisor.add(pool_child)
  |> static_supervisor.start
  |> result.replace_error("the supervisor did not start")
}
