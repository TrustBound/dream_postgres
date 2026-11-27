//// Checks that the two parts of a pair are equal.

import dream_test/types.{
  type MatchResult, AssertionFailure, CustomMatcherFailure, MatchFailed, MatchOk,
}
import gleam/option.{Some}
import gleam/string.{inspect}

/// Gives the part of a pair whose two parts are equal, for example the
/// backend of a connection before and after a step. Fails when they
/// differ, and shows both.
///
/// ```gleam
/// #("4711", "4711")
/// |> should
/// |> be_equal_parts
/// |> or_fail_with("Expected the same backend")
/// ```
pub fn be_equal_parts(result: MatchResult(#(a, a))) -> MatchResult(a) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(pair) -> equal_part_of(pair)
  }
}

fn equal_part_of(pair: #(a, a)) -> MatchResult(a) {
  case pair {
    #(first, second) if first == second -> MatchOk(first)
    _different ->
      MatchFailed(AssertionFailure(
        operator: "be_equal_parts",
        message: "",
        payload: Some(CustomMatcherFailure(
          actual: inspect(pair),
          description: "Expected the two parts of the pair to be equal",
        )),
      ))
  }
}
