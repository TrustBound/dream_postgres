import dream_postgres/client as postgres

pub fn use_production_database(config: postgres.Config) -> postgres.Config {
  config
  |> postgres.database("myapp_prod")
}
