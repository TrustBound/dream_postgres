//// A matcher that reads the cell of the chain with a codec, as a value of a
//// type of the test catalog (`fixtures/type_catalog`).

import dream_postgres/internal/cell.{type Cell, type TypeDescription}
import dream_postgres/internal/codec_type.{type Codec, type DecodeIssue}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}
import fixtures/type_catalog

/// Read the cell with `codec` as a value of the type `description`. The
/// chain goes on with the result: the value, or the issue that stops the
/// codec.
///
/// ## Example
///
/// ```gleam
/// Binary(<<7:size(32)>>)
/// |> should
/// |> decode_as(codec.int, type_catalog.int4())
/// |> be_ok()
/// |> be_equal(7)
/// |> or_fail_with("Expected 7")
/// ```
pub fn decode_as(
  result: MatchResult(Cell),
  codec: Codec(a),
  description: TypeDescription,
) -> MatchResult(Result(a, DecodeIssue)) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(value) ->
      MatchOk(codec_type.decode(codec, value, description, type_catalog.lookup))
  }
}
