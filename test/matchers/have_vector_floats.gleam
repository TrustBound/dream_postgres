//// A matcher that gives the floats of the pgvector `vector` of the chain.

import dream_postgres/vector.{type Vector}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}

/// Give the floats of the vector, in order. The chain goes on with the list.
///
/// ## Example
///
/// ```gleam
/// vector.vector_from_list([1.5, -2.0])
/// |> should
/// |> be_ok()
/// |> have_vector_floats()
/// |> be_equal([1.5, -2.0])
/// |> or_fail_with("Expected the floats 1.5 and -2.0")
/// ```
pub fn have_vector_floats(
  result: MatchResult(Vector),
) -> MatchResult(List(Float)) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(value) -> MatchOk(vector.vector_to_list(value))
  }
}
