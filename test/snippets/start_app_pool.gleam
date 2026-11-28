import dream_errors.{type Error}
import dream_postgres/config.{
  database, default_config, host, password, pool_size, user,
}
import dream_postgres/error.{type PostgresError}
import dream_postgres/pool.{type Connection, start}

pub fn start_app_pool(
  app_password: String,
) -> Result(Connection, Error(PostgresError)) {
  default_config()
  |> host("localhost")
  |> database("app")
  |> user("app")
  |> password(app_password)
  |> pool_size(15)
  |> start
}
