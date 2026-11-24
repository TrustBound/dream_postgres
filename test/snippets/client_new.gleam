import dream_postgres/client as postgres
import gleam/erlang/process

pub fn create_config() -> postgres.Config {
  let pool_name = process.new_name("my_db_pool")
  postgres.new(pool_name)
}
