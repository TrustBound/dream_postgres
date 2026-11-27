//// Extracts the tag and the row count of each statement result.

import dream_postgres/driver/query.{type StatementResult}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}
import gleam/list.{map}

/// Gives `#(tag, count)` of each statement result of a simple query, in order.
///
/// ```gleam
/// results
/// |> should
/// |> extract_statement_tags
/// |> be_equal([#("CREATE TABLE", 0), #("INSERT 0 2", 2)])
/// |> or_fail_with("Expected two results")
/// ```
pub fn extract_statement_tags(
  result: MatchResult(List(StatementResult)),
) -> MatchResult(List(#(String, Int))) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(statements) -> MatchOk(map(statements, tag_and_count))
  }
}

fn tag_and_count(statement: StatementResult) -> #(String, Int) {
  #(statement.result.tag, statement.result.count)
}
