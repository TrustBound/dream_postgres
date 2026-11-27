//// A matcher that maps a statement cache of the client to the statement setting of the driver.

import dream_postgres.{type StatementCache}
import dream_postgres/driver/connection
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}

/// Map a statement cache of the client to the statement setting of the driver. The chain goes on with the result.
///
/// ## Example
///
/// ```gleam
/// NoStatementCache
/// |> should
/// |> map_statement_cache()
/// |> be_equal(connection.UnnamedStatements)
/// |> or_fail_with("Expected UnnamedStatements")
/// ```
pub fn map_statement_cache(
  result: MatchResult(StatementCache),
) -> MatchResult(connection.StatementCaching) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(value) -> MatchOk(dream_postgres.statement_caching(value))
  }
}
