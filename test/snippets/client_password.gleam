import dream_postgres/client as postgres

pub fn use_password(config: postgres.Config) -> postgres.Config {
  config
  |> postgres.password("secret123")
}
