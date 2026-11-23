//// Connecting guide: a production config from separate settings
////
//// Builds a config from a host and a password with the builder functions,
//// and sets SSL and the application name with pog.

import dream_postgres/client as postgres
import gleam/erlang/process
import pog

pub fn production_config(
  pool_name: process.Name(pog.Message),
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
  |> pog.ssl(pog.SslVerified)
  |> pog.connection_parameter(name: "application_name", value: "myapp-web")
}
