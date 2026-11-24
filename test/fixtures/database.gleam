//// Queries for the tests that run against a pool with no database.

import dream_pog as pog

/// Runs `SELECT 1` on the connection with a 500 ms timeout.
///
/// Against a pool that has no database, the result is
/// `Error(pog.ConnectionUnavailable)`.
pub fn run_select_one(
  connection: pog.Connection,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  pog.query("SELECT 1")
  |> pog.timeout(500)
  |> pog.execute(connection)
}
