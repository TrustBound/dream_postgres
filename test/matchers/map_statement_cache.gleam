//// A matcher that maps a statement cache of the client to the statement setting of the driver.

import dream_postgres/config.{type StatementCache}
import dream_postgres/driver/connection/settings as connection_settings
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}

/// Map a statement cache of the client to the statement setting of the driver. The chain goes on with the result.
///
/// ## Example
///
/// ```gleam
/// NoStatementCache
/// |> should
/// |> map_statement_cache()
/// |> be_equal(connection_settings.UnnamedStatements)
/// |> or_fail_with("Expected UnnamedStatements")
/// ```
pub fn map_statement_cache(
  result: MatchResult(StatementCache),
) -> MatchResult(connection_settings.StatementCaching) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(value) -> MatchOk(config.statement_caching(value))
  }
}
