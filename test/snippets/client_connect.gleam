import dream_postgres/client as postgres
import gleam/erlang/process
import gleam/otp/actor
import pog

pub fn connect_database(
  pool_name: process.Name(pog.Message),
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
