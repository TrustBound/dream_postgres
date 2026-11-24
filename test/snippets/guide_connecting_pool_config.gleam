//// Connecting guide: read a URL, then change the pool settings
////
//// Reads a DATABASE_URL into a config, sets the pool size, and starts the
//// pool.

import dream_pog as pog
import dream_postgres/client as postgres
import gleam/erlang/process
import gleam/result
import snippets/guide_connecting_explain_url_error.{explain}

pub fn pool_config(
  pool_name: process.Name(pog.Message),
  database_url: String,
  pool_size: Int,
) -> Result(postgres.Config, postgres.UrlError) {
  postgres.parse_config(pool_name, database_url)
  |> result.map(postgres.pool_size(_, pool_size))
}

pub fn connect_pool(
  database_url: String,
  pool_size: Int,
) -> Result(postgres.Connection, String) {
  let pool_name = process.new_name("app_database")
  use config <- result.try(
    pool_config(pool_name, database_url, pool_size)
    |> result.map_error(explain),
  )
  postgres.connect(config)
  // The start error can hold the config, and the config holds the password
  |> result.replace_error("The database pool did not start")
}
