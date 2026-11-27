import dream_errors.{type Error}
import dream_postgres.{
  type Connection, type PostgresError, config_from_url, pool_size, start,
}
import gleam/result

/// Starts a pool of 4 connections from a database URL, such as
/// `postgresql://app:secret@db.example.com:5432/app?sslmode=verify-full`.
pub fn connect_with_url(
  database_url: String,
) -> Result(Connection, Error(PostgresError)) {
  use config <- result.try(config_from_url(database_url))
  config
  |> pool_size(4)
  |> start
}
