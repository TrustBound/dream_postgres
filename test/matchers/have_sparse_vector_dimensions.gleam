//// A matcher that gives the number of dimensions of the pgvector `sparsevec`
//// of the chain.

import dream_postgres/codecs/vector.{type SparseVector}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}

/// Give the number of dimensions of the sparse vector. The chain goes on with
/// the number.
///
/// ## Example
///
/// ```gleam
/// vector.sparse_vector_from_dict(5, dict.new())
/// |> should
/// |> be_ok()
/// |> have_sparse_vector_dimensions()
/// |> be_equal(5)
/// |> or_fail_with("Expected 5 dimensions")
/// ```
pub fn have_sparse_vector_dimensions(
  result: MatchResult(SparseVector),
) -> MatchResult(Int) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(value) -> MatchOk(vector.sparse_vector_dimensions(value))
  }
}
