//// Queries for the tests that run against a pool with no database.

import dream_postgres_client

/// Runs `SELECT 1` on the connection with a 500 ms timeout.
///
/// Against a pool that has no database, the result is
/// `Error(dream_postgres_client.ConnectionUnavailable)`.
pub fn run_select_one(
  connection: dream_postgres_client.Connection,
) -> Result(
  dream_postgres_client.Returned(Nil),
  dream_postgres_client.QueryError,
) {
  dream_postgres_client.query("SELECT 1")
  |> dream_postgres_client.timeout(500)
  |> dream_postgres_client.execute(connection)
}
