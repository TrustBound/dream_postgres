import dream_errors.{type Error}
import dream_postgres.{
  type Config, type Connection, type PostgresError, NoStatementCache, start,
  statement_cache,
}

pub fn start_pool_without_statement_cache(
  config: Config,
) -> Result(Connection, Error(PostgresError)) {
  config
  |> statement_cache(NoStatementCache)
  |> start
}
