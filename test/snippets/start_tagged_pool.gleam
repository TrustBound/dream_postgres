import dream_errors.{type Error}
import dream_postgres.{
  type Config, type Connection, type PostgresError, intercept, start,
}
import snippets/request_tagging.{log_slow_queries, tag_with_app_name}

pub fn start_tagged_pool(
  config: Config,
) -> Result(Connection, Error(PostgresError)) {
  config
  |> intercept(tag_with_app_name)
  |> intercept(log_slow_queries)
  |> start
}
