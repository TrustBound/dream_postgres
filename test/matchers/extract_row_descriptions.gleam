//// Extracts the columns of each RowDescription message.

import dream_postgres/driver/message.{
  type BackendMessage, type ResultColumn, RowDescription,
}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}
import gleam/list.{filter_map}

/// Gives the columns of each RowDescription message in the list, in order.
/// Other messages give nothing.
///
/// ```gleam
/// messages
/// |> should
/// |> extract_row_descriptions
/// |> be_equal([expected_columns])
/// |> or_fail_with("Expected one RowDescription")
/// ```
pub fn extract_row_descriptions(
  result: MatchResult(List(BackendMessage)),
) -> MatchResult(List(List(ResultColumn))) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(messages) -> MatchOk(filter_map(messages, columns_of))
  }
}

fn columns_of(message: BackendMessage) -> Result(List(ResultColumn), Nil) {
  case message {
    RowDescription(columns) -> Ok(columns)
    _other -> Error(Nil)
  }
}
