import dream_postgres/client as postgres

pub fn use_default_port(config: postgres.Config) -> postgres.Config {
  config
  |> postgres.port(5432)
}
