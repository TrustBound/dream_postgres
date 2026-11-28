import dream_errors.{type Error}
import dream_postgres/config.{type Config, intercept}
import dream_postgres/error.{type PostgresError}
import dream_postgres/pool.{type Connection, start_pool}
import snippets/request_tagging.{log_slow_queries, tag_with_app_name}

pub fn start_tagged_pool(
  config: Config,
) -> Result(Connection, Error(PostgresError)) {
  config
  |> intercept(tag_with_app_name)
  |> intercept(log_slow_queries)
  |> start_pool
}
