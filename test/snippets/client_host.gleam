import dream_postgres/client as postgres

pub fn use_local_host(config: postgres.Config) -> postgres.Config {
  config
  |> postgres.host("localhost")
}
