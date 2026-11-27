//// Extracts the first value of a pair.

import dream_test/types.{type MatchResult, MatchFailed, MatchOk}

/// Gives the first value of a pair.
///
/// ```gleam
/// copy_from(connection, "COPY t FROM STDIN", 5000, copy_inside(_, connection))
/// |> should
/// |> be_error
/// |> extract_app_failure
/// |> extract_first_of_pair
/// |> be_error
/// |> be_equal(DeadlinePassed(cancelled: False))
/// |> or_fail_with("Expected the inner script to pass its deadline")
/// ```
pub fn extract_first_of_pair(result: MatchResult(#(a, b))) -> MatchResult(a) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(#(first, _second)) -> MatchOk(first)
  }
}
