//// Extracts the name of a type description.

import dream_postgres/internal/cell.{type TypeDescription}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}

/// Gives the name of the type that the description describes.
///
/// ```gleam
/// catalog.describe(types, connection, 23, 5000)
/// |> should
/// |> be_ok
/// |> extract_type_name
/// |> be_equal("int4")
/// |> or_fail_with("Expected int4")
/// ```
pub fn extract_type_name(
  result: MatchResult(TypeDescription),
) -> MatchResult(String) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(description) -> MatchOk(description.name)
  }
}
