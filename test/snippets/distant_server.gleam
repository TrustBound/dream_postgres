import dream_postgres/config.{
  type Config, cancel_timeout, connect_timeout, health_check_interval, host,
  return_rollback_timeout, setup_timeout,
}

/// A pool on a server in another region: more time to connect and to log
/// in, less time for a cancel, and fewer health checks. Each time is in
/// milliseconds.
pub fn distant_server(config: Config) -> Config {
  config
  |> host("db.eu-west.example.com")
  |> connect_timeout(3000)
  |> setup_timeout(15_000)
  |> cancel_timeout(1000)
  |> health_check_interval(60_000)
  |> return_rollback_timeout(5000)
}
