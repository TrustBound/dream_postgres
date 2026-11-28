import dream_errors.{type Error}
import dream_postgres/config.{default_config, host}
import dream_postgres/error.{type PostgresError}
import dream_postgres/pool.{type Connection, start_pool}

pub fn start_pool_on(
  server_host: String,
) -> Result(Connection, Error(PostgresError)) {
  default_config()
  |> host(server_host)
  |> start_pool
}
