//// Extracts the SQLSTATE code of each ErrorResponse message.

import dream_postgres/driver/message.{type BackendMessage, ErrorResponse}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}
import gleam/list.{filter_map}

/// Gives the SQLSTATE code of each ErrorResponse message in the list, in
/// order. Other messages give nothing.
///
/// ```gleam
/// messages
/// |> should
/// |> extract_error_codes
/// |> be_equal(["22012"])
/// |> or_fail_with("Expected the SQLSTATE 22012")
/// ```
pub fn extract_error_codes(
  result: MatchResult(List(BackendMessage)),
) -> MatchResult(List(String)) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(messages) -> MatchOk(filter_map(messages, code_of))
  }
}

fn code_of(message: BackendMessage) -> Result(String, Nil) {
  case message {
    ErrorResponse(report) -> Ok(report.code)
    _other -> Error(Nil)
  }
}
