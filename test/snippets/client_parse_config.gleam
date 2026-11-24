import dream_postgres/client as postgres
import dream_postgres_client
import gleam/erlang/process

pub fn read_database_url(
  pool_name: process.Name(dream_postgres_client.Message),
) -> Result(postgres.Config, postgres.UrlError) {
  postgres.parse_config(pool_name, "postgresql://user:pass@localhost/myapp")
}
