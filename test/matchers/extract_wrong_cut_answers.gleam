//// Decodes each cut of one backend message, and keeps the wrong answers.

import dream_postgres/driver/decode.{decode_backend}
import dream_postgres/driver/message.{
  type BackendMessage, type DecodeStep, type ProtocolError, NeedMoreBytes,
}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}
import gleam/bit_array.{byte_size, slice}
import gleam/int.{range}
import gleam/list.{filter, map, prepend}
import gleam/result.{unwrap}

/// Cuts the bytes of one message after 0, 1, ... up to all but the last
/// byte, and decodes each cut. A cut of one message is not a message, so
/// each answer must be `Ok(NeedMoreBytes)`. Gives each other answer, with
/// the length of its cut. An empty list is the right result.
///
/// ```gleam
/// <<"1", 4:32>>
/// |> should
/// |> extract_wrong_cut_answers
/// |> be_equal([])
/// |> or_fail_with("Expected NeedMoreBytes for every cut")
/// ```
pub fn extract_wrong_cut_answers(
  result: MatchResult(BitArray),
) -> MatchResult(
  List(#(Int, Result(DecodeStep(BackendMessage), ProtocolError))),
) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(bytes) -> MatchOk(wrong_answers(bytes))
  }
}

fn wrong_answers(
  bytes: BitArray,
) -> List(#(Int, Result(DecodeStep(BackendMessage), ProtocolError))) {
  range(from: 0, to: byte_size(bytes), with: [], run: prepend)
  |> map(cut_answer(bytes, _))
  |> filter(is_not_need_more_bytes)
}

fn cut_answer(
  bytes: BitArray,
  length: Int,
) -> #(Int, Result(DecodeStep(BackendMessage), ProtocolError)) {
  let cut = slice(bytes, 0, length) |> unwrap(<<>>)
  #(length, decode_backend(cut))
}

fn is_not_need_more_bytes(
  answer: #(Int, Result(DecodeStep(BackendMessage), ProtocolError)),
) -> Bool {
  answer.1 != Ok(NeedMoreBytes)
}
