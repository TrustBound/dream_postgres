//// Extracts the distinct items of a list.

import dream_test/types.{type MatchResult, MatchFailed, MatchOk}
import gleam/list.{unique}

/// Gives the items of the list with each value once, in the order of
/// their first place.
///
/// ```gleam
/// ["4711", "4712", "4711"]
/// |> should
/// |> extract_distinct_items
/// |> have_length(2)
/// |> or_fail_with("Expected two backends")
/// ```
pub fn extract_distinct_items(
  result: MatchResult(List(a)),
) -> MatchResult(List(a)) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(items) -> MatchOk(unique(items))
  }
}
