//// A matcher that gives the floats of the pgvector `halfvec` of the chain.

import dream_postgres/codecs/vector.{type HalfVector}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}

/// Give the floats of the half vector, in order. The chain goes on with the
/// list.
///
/// ## Example
///
/// ```gleam
/// vector.half_vector_from_list([1.5, -2.0])
/// |> should
/// |> be_ok()
/// |> have_half_vector_floats()
/// |> be_equal([1.5, -2.0])
/// |> or_fail_with("Expected the floats 1.5 and -2.0")
/// ```
pub fn have_half_vector_floats(
  result: MatchResult(HalfVector),
) -> MatchResult(List(Float)) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(value) -> MatchOk(vector.half_vector_to_list(value))
  }
}
