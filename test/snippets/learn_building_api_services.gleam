//// Lesson 2: Services holding the database connection pool
//// (src/services.gleam)

import dream_postgres_client
import gleam/erlang/process
import gleam/option.{Some}
import gleam/otp/actor
import gleam/result

pub type Services {
  Services(db: dream_postgres_client.Connection)
}

pub fn initialize_services() -> Result(Services, actor.StartError) {
  create_database_config()
  |> dream_postgres_client.start()
  |> result.map(fn(started) { Services(db: started.data) })
}

pub fn create_database_config() -> dream_postgres_client.Config {
  dream_postgres_client.default_config(pool_name: process.new_name("db_pool"))
  |> dream_postgres_client.host("localhost")
  |> dream_postgres_client.port(5432)
  |> dream_postgres_client.database("myapp")
  |> dream_postgres_client.user("postgres")
  |> dream_postgres_client.password(Some("postgres"))
  |> dream_postgres_client.pool_size(10)
}
