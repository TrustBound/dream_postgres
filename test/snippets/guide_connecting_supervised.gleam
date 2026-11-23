//// Connecting guide: put the pool under a supervisor
////
//// Starts the pool as a child of a supervisor, and makes a connection from
//// the pool name.

import dream_postgres/client as postgres
import gleam/erlang/process
import gleam/otp/static_supervisor as supervisor
import gleam/result
import pog
import snippets/guide_connecting_explain_url_error.{explain}

pub fn start_supervised(
  database_url: String,
) -> Result(postgres.Connection, String) {
  let pool_name = process.new_name("app_database")
  use config <- result.try(
    postgres.parse_config(pool_name, database_url)
    |> result.map_error(explain),
  )
  use _supervisor <- result.try(
    supervisor.new(supervisor.OneForOne)
    |> supervisor.add(pog.supervised(postgres.pool_size(config, 15)))
    |> supervisor.start()
    |> result.replace_error("The supervisor did not start"),
  )
  Ok(pog.named_connection(pool_name))
}
