//// A matcher that gives the text of the JSON document of the chain.

import dream_postgres/codecs/json.{type Json}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}

/// Give the text of the JSON document, as it was read or made. The chain
/// goes on with the text.
///
/// ## Example
///
/// ```gleam
/// json.from_string("{\"a\": 1}")
/// |> should
/// |> be_ok()
/// |> have_json_text()
/// |> be_equal("{\"a\": 1}")
/// |> or_fail_with("Expected the same text")
/// ```
pub fn have_json_text(result: MatchResult(Json)) -> MatchResult(String) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(value) -> MatchOk(json.to_string(value))
  }
}
