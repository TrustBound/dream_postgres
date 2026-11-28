import dream_errors.{type Error}
import dream_postgres/codec.{text}
import dream_postgres/config.{type Config}
import dream_postgres/error.{type PostgresError, describe}
import dream_postgres/pool.{type PoolName, named_connection, supervised}
import dream_postgres/query.{one, query}
import dream_postgres/row.{single}
import gleam/otp/actor
import gleam/otp/static_supervisor.{type Supervisor}
import gleam/result

/// Starts the app's supervisor with the pool under it. The pool runs
/// under `pool_name`, also after a restart.
pub fn start_supervisor(
  config: Config,
  pool_name: PoolName,
) -> Result(actor.Started(Supervisor), String) {
  use pool_child <- result.try(
    supervised(config, name: pool_name)
    |> result.map_error(describe),
  )
  static_supervisor.new(static_supervisor.OneForOne)
  |> static_supervisor.add(pool_child)
  |> static_supervisor.start
  |> result.replace_error("the supervisor did not start")
}

/// Any process can reach the pool by its name.
pub fn current_database(
  pool_name: PoolName,
) -> Result(String, Error(PostgresError)) {
  "SELECT current_database()"
  |> query
  |> one(single(text), named_connection(pool_name))
}
