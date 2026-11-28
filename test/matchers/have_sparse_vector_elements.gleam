//// A matcher that gives the elements of the pgvector `sparsevec` of the
//// chain.

import dream_postgres/vector.{type SparseVector}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}
import gleam/dict.{type Dict}

/// Give the elements of the sparse vector that are not zero, each its index
/// and its float. The chain goes on with the dict.
///
/// ## Example
///
/// ```gleam
/// vector.sparse_vector_from_dict(5, dict.from_list([#(3, 2.5)]))
/// |> should
/// |> be_ok()
/// |> have_sparse_vector_elements()
/// |> be_equal(dict.from_list([#(3, 2.5)]))
/// |> or_fail_with("Expected 2.5 at index 3")
/// ```
pub fn have_sparse_vector_elements(
  result: MatchResult(SparseVector),
) -> MatchResult(Dict(Int, Float)) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(value) -> MatchOk(vector.sparse_vector_to_dict(value))
  }
}
