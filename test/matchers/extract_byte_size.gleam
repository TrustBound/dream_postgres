//// Extracts the number of bytes of a bit array.

import dream_test/types.{type MatchResult, MatchFailed, MatchOk}
import gleam/bit_array

/// Gives the number of bytes of the bit array.
///
/// ```gleam
/// client_final(first, "pencil", server_first)
/// |> should
/// |> be_ok
/// |> extract_client_final_message
/// |> extract_byte_size
/// |> be_equal(1020)
/// |> or_fail_with("Expected a client-final-message of 1020 bytes")
/// ```
pub fn extract_byte_size(result: MatchResult(BitArray)) -> MatchResult(Int) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(bytes) -> MatchOk(bit_array.byte_size(bytes))
  }
}
