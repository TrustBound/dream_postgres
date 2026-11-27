import dream_errors.{type Error}
import dream_postgres.{
  type Connection, type PostgresError, default_config, host, start,
}

pub fn start_pool_on(
  server_host: String,
) -> Result(Connection, Error(PostgresError)) {
  default_config()
  |> host(server_host)
  |> start
}
