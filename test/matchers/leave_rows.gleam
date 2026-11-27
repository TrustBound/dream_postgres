//// A matcher that checks the ids that stayed in the table of a run with a
//// table, and goes on with what the work gave.

import dream_test/types.{
  type MatchResult, AssertionFailure, EqualityFailure, MatchFailed, MatchOk,
}
import gleam/option.{Some}
import gleam/string
import matchers/run_with_table.{type TableRun}

/// Check that the ids that stayed in the table are `expected`, lowest
/// first. The chain goes on with what the work gave.
///
/// ## Example
///
/// ```gleam
/// pools
/// |> should
/// |> run_with_table("kept_rows", fn(held) {
///   client_statements.insert(held, "kept_rows", 1)
/// })
/// |> leave_rows([1])
/// |> be_ok()
/// |> be_equal(1)
/// |> or_fail_with("Expected one row inserted and kept")
/// ```
pub fn leave_rows(
  result: MatchResult(TableRun(a)),
  expected: List(Int),
) -> MatchResult(a) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(table_run) -> check_rows(table_run, expected)
  }
}

fn check_rows(table_run: TableRun(a), expected: List(Int)) -> MatchResult(a) {
  case table_run.rows == expected {
    True -> MatchOk(table_run.outcome)
    False ->
      MatchFailed(AssertionFailure(
        operator: "leave_rows",
        message: "",
        payload: Some(EqualityFailure(
          actual: string.inspect(table_run.rows),
          expected: string.inspect(expected),
        )),
      ))
  }
}
