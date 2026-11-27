import dream_errors.{type Error}
import dream_postgres.{
  type Connection, type PostgresError, database, default_config, host, password,
  pool_size, start, user,
}

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
