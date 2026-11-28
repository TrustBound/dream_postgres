//// A matcher that gives the cells of the rows of an outcome of an
//// interceptor.

import dream_postgres/copy/request.{CopyRows, DatabaseRows, RecordedRows}
import dream_postgres/driver/cell.{type Cell}
import dream_postgres/interceptor.{
  type Outcome, CopyFromAnswer, CopyToAnswer, SqlAnswer, StatementAnswer,
}
import dream_test/types.{
  type MatchResult, AssertionFailure, CustomMatcherFailure, MatchFailed, MatchOk,
}
import gleam/list
import gleam/option.{Some}
import gleam/string

/// Give the cells of each row of the answer: the rows of a statement, of
/// each statement of a `run_sql` call in order, or of a recorded COPY TO. An
/// error, the count of a COPY FROM and the rows of a database fail.
///
/// ## Example
///
/// ```gleam
/// normalize.generated_uuids(keep: [])(request, fn(_request) { answer })
/// |> should
/// |> extract_answer_rows()
/// |> be_equal([[Binary(placeholder_bytes)]])
/// |> or_fail_with("Expected the placeholder")
/// ```
pub fn extract_answer_rows(
  result: MatchResult(Outcome),
) -> MatchResult(List(List(Cell))) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(outcome) -> rows_of(outcome)
  }
}

fn rows_of(outcome: Outcome) -> MatchResult(List(List(Cell))) {
  case outcome {
    Ok(StatementAnswer(result:, ..)) -> MatchOk(result.rows)
    Ok(SqlAnswer(results:)) ->
      MatchOk(list.flat_map(results, fn(sql_result) { sql_result.rows }))
    Ok(CopyToAnswer(rows: CopyRows(source: RecordedRows(rows:, ..), ..), ..)) ->
      MatchOk(rows)
    Ok(CopyToAnswer(rows: CopyRows(source: DatabaseRows(..), ..), ..))
    | Ok(CopyFromAnswer(..))
    | Error(_) -> no_rows(outcome)
  }
}

fn no_rows(outcome: Outcome) -> MatchResult(List(List(Cell))) {
  MatchFailed(AssertionFailure(
    operator: "extract_answer_rows",
    message: "",
    payload: Some(CustomMatcherFailure(
      actual: string.inspect(outcome),
      description: "expected an answer with rows",
    )),
  ))
}
