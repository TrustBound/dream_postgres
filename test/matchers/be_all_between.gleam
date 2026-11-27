//// Checks that every number of a list lies in a range.

import dream_test/types.{
  type MatchResult, AssertionFailure, CustomMatcherFailure, MatchFailed, MatchOk,
}
import gleam/int.{to_string}
import gleam/list.{filter}
import gleam/option.{Some}
import gleam/string.{inspect}

/// Passes the list on when each number is at least `lowest` and at most
/// `highest`. Fails with the numbers outside the range.
///
/// ```gleam
/// draws
/// |> should
/// |> be_all_between(lowest: 0, highest: 100)
/// |> or_fail_with("Expected each wait from 0 to 100")
/// ```
pub fn be_all_between(
  result: MatchResult(List(Int)),
  lowest lowest: Int,
  highest highest: Int,
) -> MatchResult(List(Int)) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(numbers) -> numbers_in_range(numbers, lowest, highest)
  }
}

fn numbers_in_range(
  numbers: List(Int),
  lowest: Int,
  highest: Int,
) -> MatchResult(List(Int)) {
  case filter(numbers, fn(number) { number < lowest || number > highest }) {
    [] -> MatchOk(numbers)
    outside ->
      MatchFailed(AssertionFailure(
        operator: "be_all_between",
        message: "",
        payload: Some(CustomMatcherFailure(
          actual: inspect(outside),
          description: "Expected each number from "
            <> to_string(lowest)
            <> " to "
            <> to_string(highest),
        )),
      ))
  }
}
