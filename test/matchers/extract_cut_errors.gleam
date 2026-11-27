//// Decodes each cut of a byte stream, and keeps the protocol errors.

import dream_postgres/driver/decode.{decode_backend}
import dream_postgres/driver/message.{type ProtocolError, Decoded, NeedMoreBytes}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}
import gleam/bit_array.{byte_size, slice}
import gleam/int.{range}
import gleam/list.{filter_map, prepend}
import gleam/pair
import gleam/result.{map, unwrap}

/// Cuts the bytes after 0, 1, ... up to all but the last byte, and decodes
/// the messages of each cut until it ends inside one. A cut can end inside
/// a message, but it must never give a protocol error. Gives each error,
/// with the length of its cut. An empty list is the right result.
///
/// ```gleam
/// recorded_bytes
/// |> should
/// |> extract_cut_errors
/// |> be_equal([])
/// |> or_fail_with("Expected no error for any cut")
/// ```
pub fn extract_cut_errors(
  result: MatchResult(BitArray),
) -> MatchResult(List(#(Int, ProtocolError))) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(bytes) -> MatchOk(cut_errors(bytes))
  }
}

fn cut_errors(bytes: BitArray) -> List(#(Int, ProtocolError)) {
  range(from: 0, to: byte_size(bytes), with: [], run: prepend)
  |> filter_map(cut_error(bytes, _))
}

fn cut_error(
  bytes: BitArray,
  length: Int,
) -> Result(#(Int, ProtocolError), Nil) {
  let cut = slice(bytes, 0, length) |> unwrap(<<>>)
  decode_error(cut)
  |> map(pair.new(length, _))
}

fn decode_error(bytes: BitArray) -> Result(ProtocolError, Nil) {
  case decode_backend(bytes) {
    Ok(Decoded(_message, rest)) -> decode_error(rest)
    Ok(NeedMoreBytes) -> Error(Nil)
    Error(error) -> Ok(error)
  }
}
