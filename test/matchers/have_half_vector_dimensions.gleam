//// A matcher that gives the number of dimensions of the pgvector `halfvec` of
//// the chain.

import dream_postgres/vector.{type HalfVector}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}

/// Give the number of dimensions of the half vector. The chain goes on with
/// the number.
///
/// ## Example
///
/// ```gleam
/// vector.half_vector_from_list([1.5, -2.0])
/// |> should
/// |> be_ok()
/// |> have_half_vector_dimensions()
/// |> be_equal(2)
/// |> or_fail_with("Expected 2 dimensions")
/// ```
pub fn have_half_vector_dimensions(
  result: MatchResult(HalfVector),
) -> MatchResult(Int) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(value) -> MatchOk(vector.half_vector_dimensions(value))
  }
}
