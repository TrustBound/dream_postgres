//// A matcher that gives the dimensions and the elements of the sparse
//// vector of the chain.

import dream_postgres/codecs/vector.{type SparseVector}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}
import gleam/dict.{type Dict}

/// Give the number of dimensions and the elements that are not zero, by
/// 0-based index. The chain goes on with the pair.
///
/// ## Example
///
/// ```gleam
/// vector.sparse_vector_from_dict(5, dict.from_list([#(0, 1.5)]))
/// |> should
/// |> be_ok()
/// |> have_sparse_vector_parts()
/// |> be_equal(#(5, dict.from_list([#(0, 1.5)])))
/// |> or_fail_with("Expected 5 dimensions and one element")
/// ```
pub fn have_sparse_vector_parts(
  result: MatchResult(SparseVector),
) -> MatchResult(#(Int, Dict(Int, Float))) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(value) ->
      MatchOk(#(
        vector.sparse_vector_dimensions(value),
        vector.sparse_vector_to_dict(value),
      ))
  }
}
