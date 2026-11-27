import dream_postgres.{type Config, checkout_timeout, pool_size, query_timeout}

/// A pool for a service with many short queries: 20 connections, at most
/// 2 seconds for each query, and at most 500 ms of wait for a free
/// connection.
pub fn busy_service(config: Config) -> Config {
  config
  |> pool_size(20)
  |> query_timeout(2000)
  |> checkout_timeout(500)
}
