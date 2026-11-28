import dream_errors.{type Error}
import dream_postgres/config.{pool_size}
import dream_postgres/error.{type PostgresError}
import dream_postgres/pool.{type Connection, start_pool}
import dream_postgres/url.{parse_database_url}
import gleam/result

/// Starts a pool of 4 connections from a database URL, such as
/// `postgresql://app:secret@db.example.com:5432/app?sslmode=verify-full`.
pub fn connect_with_url(
  database_url: String,
) -> Result(Connection, Error(PostgresError)) {
  use config <- result.try(parse_database_url(database_url))
  config
  |> pool_size(4)
  |> start_pool
}
