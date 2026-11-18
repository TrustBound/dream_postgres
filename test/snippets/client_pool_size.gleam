import dream_postgres/client as postgres

pub fn allow_twenty_connections(config: postgres.Config) -> postgres.Config {
  config
  // Allow up to 20 connections at the same time
  |> postgres.pool_size(20)
}
