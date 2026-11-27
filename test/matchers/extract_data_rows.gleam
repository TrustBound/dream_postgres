//// Extracts the first values of each DataRow message.

import dream_postgres/driver/message.{type BackendMessage, DataRow}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}
import gleam/list.{filter_map, take}
import gleam/option.{type Option}

/// Gives the first `columns` values of each DataRow message in the list,
/// in order. Other messages give nothing. A `None` value is a NULL.
///
/// ```gleam
/// messages
/// |> should
/// |> extract_data_rows(columns: 2)
/// |> be_equal([[Some(<<"ada":utf8>>), None]])
/// |> or_fail_with("Expected ada and NULL")
/// ```
pub fn extract_data_rows(
  result: MatchResult(List(BackendMessage)),
  columns count: Int,
) -> MatchResult(List(List(Option(BitArray)))) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(messages) -> MatchOk(filter_map(messages, values_of(_, count)))
  }
}

fn values_of(
  message: BackendMessage,
  count: Int,
) -> Result(List(Option(BitArray)), Nil) {
  case message {
    DataRow(values) -> Ok(take(values, count))
    _other -> Error(Nil)
  }
}
