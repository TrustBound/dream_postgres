//// A matcher that gives the floats of each vector of a list in the chain.

import dream_postgres/vector.{type Vector}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}
import gleam/list

/// Give the floats of each vector, in order. The chain goes on with the
/// lists of floats.
///
/// ## Example
///
/// ```gleam
/// [vector.vector_from_list([1.0]), vector.vector_from_list([2.0])]
/// |> result.all
/// |> should
/// |> be_ok()
/// |> have_each_vector_floats()
/// |> be_equal([[1.0], [2.0]])
/// |> or_fail_with("Expected the floats of both vectors")
/// ```
pub fn have_each_vector_floats(
  result: MatchResult(List(Vector)),
) -> MatchResult(List(List(Float))) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(values) -> MatchOk(list.map(values, vector.vector_to_list))
  }
}
