//// Extracts the column names of the new description of a changed statement.

import dream_postgres/driver/connection/request_failure.{
  type RunError, RunStatementChanged,
}
import dream_postgres/internal/cell.{type ColumnDescription}
import dream_test/types.{
  type MatchResult, AssertionFailure, CustomMatcherFailure, MatchFailed, MatchOk,
}
import gleam/list.{map}
import gleam/option.{Some}
import gleam/string.{inspect}

/// Gives the column names, in column order, of the new description that a
/// `RunStatementChanged` error carries. Fails for other errors.
///
/// ```gleam
/// run(connection, "SELECT * FROM changing", [], [], 5000)
/// |> should
/// |> be_error
/// |> extract_changed_column_names
/// |> be_equal(["a", "b"])
/// |> or_fail_with("Expected RunStatementChanged with both columns")
/// ```
pub fn extract_changed_column_names(
  result: MatchResult(RunError),
) -> MatchResult(List(String)) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(error) -> changed_column_names_of(error)
  }
}

fn changed_column_names_of(error: RunError) -> MatchResult(List(String)) {
  case error {
    RunStatementChanged(description) ->
      MatchOk(map(description.columns, column_name))
    _other ->
      MatchFailed(AssertionFailure(
        operator: "extract_changed_column_names",
        message: "",
        payload: Some(CustomMatcherFailure(
          actual: inspect(error),
          description: "Expected RunStatementChanged",
        )),
      ))
  }
}

fn column_name(column: ColumnDescription) -> String {
  column.name
}
