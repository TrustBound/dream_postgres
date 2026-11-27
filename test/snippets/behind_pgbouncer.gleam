import dream_postgres.{type Config, NoStatementCache, statement_cache}

/// Prepares each statement again for each run, with no name, because
/// PgBouncer in transaction mode can send the next transaction to another
/// server session.
pub fn behind_pgbouncer(config: Config) -> Config {
  config
  |> statement_cache(NoStatementCache)
}
