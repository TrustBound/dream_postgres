//// A matcher that gives the summary of each error of a list of outcomes.

import dream_errors.{type Error}
import dream_postgres/error.{type PostgresError}
import dream_test/types.{
  type MatchResult, AssertionFailure, CustomMatcherFailure, MatchFailed, MatchOk,
}
import gleam/list
import gleam/option.{Some}
import gleam/string
import matchers/summarise_error.{summarise_error}

/// Give the summary of the error of each outcome, in order, as
/// `summarise_error` gives it. The chain fails when an outcome is `Ok`.
///
/// ## Example
///
/// ```gleam
/// [run_sql("SELECT 1", stopped), run_sql("SELECT 2", stopped)]
/// |> should
/// |> summarise_errors()
/// |> be_equal(["unavailable PoolStopped", "unavailable PoolStopped"])
/// |> or_fail_with("Expected each call to be unavailable")
/// ```
pub fn summarise_errors(
  result: MatchResult(List(Result(a, Error(PostgresError)))),
) -> MatchResult(List(String)) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(outcomes) -> summaries(outcomes)
  }
}

fn summaries(
  outcomes: List(Result(a, Error(PostgresError))),
) -> MatchResult(List(String)) {
  case list.try_map(outcomes, summary) {
    Ok(texts) -> MatchOk(texts)
    Error(value) ->
      MatchFailed(AssertionFailure(
        operator: "summarise_errors",
        message: "",
        payload: Some(CustomMatcherFailure(
          actual: "Ok " <> value,
          description: "expected an error for each outcome",
        )),
      ))
  }
}

fn summary(outcome: Result(a, Error(PostgresError))) -> Result(String, String) {
  case outcome {
    Ok(value) -> Error(string.inspect(value))
    Error(failure) -> summary_text(summarise_error(MatchOk(failure)))
  }
}

fn summary_text(summarised: MatchResult(String)) -> Result(String, String) {
  case summarised {
    MatchOk(text) -> Ok(text)
    MatchFailed(failure) -> Error(failure.operator)
  }
}
