//// Extracts the second value of a pair.

import dream_test/types.{type MatchResult, MatchFailed, MatchOk}

/// Gives the second value of a pair.
///
/// ```gleam
/// copy_from(connection, "COPY t FROM STDIN", 5000, copy_inside(_, connection))
/// |> should
/// |> be_error
/// |> extract_app_failure
/// |> extract_second_of_pair
/// |> be_error
/// |> extract_copy_driver_error
/// |> be_equal(DeadlinePassed(cancelled: False))
/// |> or_fail_with("Expected the inner COPY to pass its deadline")
/// ```
pub fn extract_second_of_pair(result: MatchResult(#(a, b))) -> MatchResult(b) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(#(_first, second)) -> MatchOk(second)
  }
}
