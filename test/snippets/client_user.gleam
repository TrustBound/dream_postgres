import dream_postgres/client as postgres

pub fn use_postgres_user(config: postgres.Config) -> postgres.Config {
  config
  |> postgres.user("postgres")
}
