//// Extracts the secret key length of each BackendKeyData message.

import dream_postgres/driver/message.{type BackendMessage, BackendKeyData}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}
import gleam/bit_array.{byte_size}
import gleam/list.{filter_map}

/// Gives the byte length of the secret key of each BackendKeyData message
/// in the list, in order. Other messages give nothing.
///
/// ```gleam
/// messages
/// |> should
/// |> extract_secret_key_lengths
/// |> be_equal([32])
/// |> or_fail_with("Expected one 32-byte key")
/// ```
pub fn extract_secret_key_lengths(
  result: MatchResult(List(BackendMessage)),
) -> MatchResult(List(Int)) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(messages) -> MatchOk(filter_map(messages, secret_key_length))
  }
}

fn secret_key_length(message: BackendMessage) -> Result(Int, Nil) {
  case message {
    BackendKeyData(secret_key:, ..) -> Ok(byte_size(secret_key))
    _other -> Error(Nil)
  }
}
