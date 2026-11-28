import dream_errors.{type Error}
import dream_postgres/config.{type Config, NoStatementCache, statement_cache}
import dream_postgres/error.{type PostgresError}
import dream_postgres/pool.{type Connection, start}

pub fn start_pool_without_statement_cache(
  config: Config,
) -> Result(Connection, Error(PostgresError)) {
  config
  |> statement_cache(NoStatementCache)
  |> start
}
