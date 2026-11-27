//// Checks that the two parts of a pair are different.

import dream_test/types.{
  type MatchResult, AssertionFailure, CustomMatcherFailure, MatchFailed, MatchOk,
}
import gleam/option.{Some}
import gleam/string.{inspect}

/// Gives a pair whose two parts are different, for example the backends
/// of two connections. Fails when they are equal, and shows both.
///
/// ```gleam
/// #("4711", "4712")
/// |> should
/// |> be_different_parts
/// |> or_fail_with("Expected a new backend")
/// ```
pub fn be_different_parts(
  result: MatchResult(#(a, a)),
) -> MatchResult(#(a, a)) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(pair) -> different_pair(pair)
  }
}

fn different_pair(pair: #(a, a)) -> MatchResult(#(a, a)) {
  case pair {
    #(first, second) if first != second -> MatchOk(pair)
    _equal ->
      MatchFailed(AssertionFailure(
        operator: "be_different_parts",
        message: "",
        payload: Some(CustomMatcherFailure(
          actual: inspect(pair),
          description: "Expected the two parts of the pair to be different",
        )),
      ))
  }
}
