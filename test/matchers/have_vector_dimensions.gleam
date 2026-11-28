//// A matcher that gives the number of dimensions of the pgvector `vector` of
//// the chain.

import dream_postgres/vector.{type Vector}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}

/// Give the number of dimensions of the vector. The chain goes on with the
/// number.
///
/// ## Example
///
/// ```gleam
/// vector.vector_from_list([1.5, -2.0])
/// |> should
/// |> be_ok()
/// |> have_vector_dimensions()
/// |> be_equal(2)
/// |> or_fail_with("Expected 2 dimensions")
/// ```
pub fn have_vector_dimensions(result: MatchResult(Vector)) -> MatchResult(Int) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(value) -> MatchOk(vector.vector_dimensions(value))
  }
}
