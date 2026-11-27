//// A matcher that gives the cause of a Dream error.

import dream_errors.{type Error}
import dream_test/types.{
  type MatchResult, AssertionFailure, CustomMatcherFailure, MatchFailed, MatchOk,
}
import gleam/option.{None, Some}

/// Give the cause of the error, the package's own error. The chain fails for
/// `NotFound`, which has no cause.
///
/// ## Example
///
/// ```gleam
/// runner.one(query, row, executor, [])
/// |> should
/// |> be_error()
/// |> have_cause()
/// |> have_reason()
/// |> be_equal(TooManyRows)
/// |> or_fail_with("Expected TooManyRows")
/// ```
pub fn have_cause(result: MatchResult(Error(cause))) -> MatchResult(cause) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(error) -> cause_of(error)
  }
}

fn cause_of(error: Error(cause)) -> MatchResult(cause) {
  case dream_errors.cause(error) {
    Some(cause) -> MatchOk(cause)
    None ->
      MatchFailed(AssertionFailure(
        operator: "have_cause",
        message: "",
        payload: Some(CustomMatcherFailure(
          actual: dream_errors.message(error),
          description: "expected an error with a cause, not NotFound",
        )),
      ))
  }
}
