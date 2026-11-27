//// Extracts the first item of a list.

import dream_test/types.{
  type MatchResult, AssertionFailure, CustomMatcherFailure, MatchFailed, MatchOk,
}
import gleam/option.{Some}

/// Gives the first item of the list. Fails when the list is empty.
///
/// ```gleam
/// [1, 2, 3]
/// |> should
/// |> extract_first
/// |> be_equal(1)
/// |> or_fail_with("Expected 1 first")
/// ```
pub fn extract_first(result: MatchResult(List(a))) -> MatchResult(a) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(items) -> first_of(items)
  }
}

fn first_of(items: List(a)) -> MatchResult(a) {
  case items {
    [first, ..] -> MatchOk(first)
    [] ->
      MatchFailed(AssertionFailure(
        operator: "extract_first",
        message: "",
        payload: Some(CustomMatcherFailure(
          actual: "[]",
          description: "Expected a list with at least one item",
        )),
      ))
  }
}
