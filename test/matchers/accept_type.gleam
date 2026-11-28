//// A matcher that tells if the codec of the chain takes a type of the test
//// catalog (`fixtures/type_catalog`).

import dream_postgres/codecs/codec_type.{type Codec}
import dream_postgres/driver/cell.{type TypeDescription}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}
import fixtures/type_catalog

/// Tell if the codec takes the type `description`. The chain goes on with
/// `True` or `False`.
///
/// ## Example
///
/// ```gleam
/// codec.int
/// |> should
/// |> accept_type(type_catalog.int2())
/// |> be_true()
/// |> or_fail_with("Expected int to take int2")
/// ```
pub fn accept_type(
  result: MatchResult(Codec(a)),
  description: TypeDescription,
) -> MatchResult(Bool) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(codec) ->
      MatchOk(codec_type.accepts(codec, description, type_catalog.lookup))
  }
}
