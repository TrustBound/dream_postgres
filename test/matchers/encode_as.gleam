//// A matcher that writes the value of the chain with a codec, as a value of
//// a type of the test catalog (`fixtures/type_catalog`).

import dream_postgres/codecs/codec_type.{type Codec}
import dream_postgres/driver/cell.{type Cell, type TypeDescription}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}
import fixtures/type_catalog

/// Write the value with `codec` as a value of the type `description`. The
/// chain goes on with the result: the cell, or the reason that the codec
/// cannot write the value.
///
/// ## Example
///
/// ```gleam
/// 7
/// |> should
/// |> encode_as(codec.int, type_catalog.int4())
/// |> be_ok()
/// |> be_equal(Binary(<<7:size(32)>>))
/// |> or_fail_with("Expected the four bytes of 7")
/// ```
pub fn encode_as(
  result: MatchResult(a),
  codec: Codec(a),
  description: TypeDescription,
) -> MatchResult(Result(Cell, String)) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(value) ->
      MatchOk(codec_type.encode(codec, value, description, type_catalog.lookup))
  }
}
