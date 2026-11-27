//// Writes bytes as upper-case hexadecimal text.

import dream_test/types.{type MatchResult, MatchFailed, MatchOk}
import gleam/bit_array.{base16_encode}

/// Gives the bytes as base 16 text, two upper-case digits for each byte.
///
/// ```gleam
/// <<1, 171>>
/// |> should
/// |> extract_base16
/// |> be_equal("01AB")
/// |> or_fail_with("Expected 01AB")
/// ```
pub fn extract_base16(result: MatchResult(BitArray)) -> MatchResult(String) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(bytes) -> MatchOk(base16_encode(bytes))
  }
}
