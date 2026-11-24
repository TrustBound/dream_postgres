import dream_postgres/client as postgres
import dream_postgres_client
import gleam/erlang/process
import gleam/otp/actor

pub fn connect_database(
  pool_name: process.Name(dream_postgres_client.Message),
) -> Result(postgres.Connection, actor.StartError) {
  postgres.new(pool_name)
  |> postgres.host("localhost")
  |> postgres.port(5432)
  |> postgres.database("myapp")
  |> postgres.user("postgres")
  |> postgres.password("secret")
  |> postgres.pool_size(15)
  |> postgres.connect()
}
