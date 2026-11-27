//// Checks that a query step waits for the next message.

import dream_postgres/driver/query.{type Step, Wait}
import dream_test/types.{
  type MatchResult, AssertionFailure, CustomMatcherFailure, MatchFailed, MatchOk,
}
import gleam/option.{Some}
import gleam/string.{inspect}

/// Passes the state of a `Wait` step on. Fails for any other step.
///
/// ```gleam
/// step_prepare(start.state, ParseComplete)
/// |> should
/// |> be_ok
/// |> be_wait
/// |> or_fail_with("Expected Wait after ParseComplete")
/// ```
pub fn be_wait(
  result: MatchResult(Step(state, outcome)),
) -> MatchResult(state) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(step) -> state_of(step)
  }
}

fn state_of(step: Step(state, outcome)) -> MatchResult(state) {
  case step {
    Wait(state) -> MatchOk(state)
    _other ->
      MatchFailed(AssertionFailure(
        operator: "be_wait",
        message: "",
        payload: Some(CustomMatcherFailure(
          actual: inspect(step),
          description: "Expected Wait",
        )),
      ))
  }
}
