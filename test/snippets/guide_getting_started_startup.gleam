//// Getting started guide: Step 2
////
//// Starts a connection pool from a DATABASE_URL, then runs `SELECT 1` so
//// that the program stops at startup when the database does not answer.

import dream_postgres/client as postgres
import gleam/result
import gleam/string
import pog

pub type StartupError {
  BadDatabaseUrl(error: postgres.UrlError)
  PoolDidNotStart
  DatabaseDidNotAnswer(error: pog.QueryError)
}

pub fn start(
  database_url: String,
) -> Result(postgres.Connection, StartupError) {
  use connection <- result.try(
    postgres.from_url(database_url)
    |> result.map_error(startup_error),
  )
  use _returned <- result.try(
    pog.query("SELECT 1")
    |> pog.execute(connection)
    |> result.map_error(DatabaseDidNotAnswer),
  )
  Ok(connection)
}

fn startup_error(error: postgres.FromUrlError) -> StartupError {
  case error {
    postgres.InvalidUrl(url_error) -> BadDatabaseUrl(url_error)
    postgres.PoolStartExited -> PoolDidNotStart
  }
}

pub fn describe(error: StartupError) -> String {
  case error {
    BadDatabaseUrl(url_error) ->
      "DATABASE_URL is not valid: " <> string.inspect(url_error)
    PoolDidNotStart -> "The database pool did not start"
    DatabaseDidNotAnswer(query_error) ->
      "The database did not answer: " <> string.inspect(query_error)
  }
}
