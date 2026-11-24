//// Connecting guide: a production config from separate settings
////
//// Builds a config from a host and a password with the builder functions,
//// and sets SSL and the application name with dream_postgres_client.

import dream_postgres/client as postgres
import dream_postgres_client
import gleam/erlang/process

pub fn production_config(
  pool_name: process.Name(dream_postgres_client.Message),
  host: String,
  password: String,
) -> postgres.Config {
  postgres.new(pool_name)
  |> postgres.host(host)
  |> postgres.port(5432)
  |> postgres.database("myapp")
  |> postgres.user("myapp")
  |> postgres.password(password)
  |> postgres.pool_size(20)
  |> dream_postgres_client.ssl(dream_postgres_client.SslVerified)
  |> dream_postgres_client.connection_parameter(
    name: "application_name",
    value: "myapp-web",
  )
}
