import dream_postgres/client as postgres
import gleam/erlang/process
import pog

pub fn read_database_url(
  pool_name: process.Name(pog.Message),
) -> Result(postgres.Config, postgres.UrlError) {
  postgres.parse_config(pool_name, "postgresql://user:pass@localhost/myapp")
}
