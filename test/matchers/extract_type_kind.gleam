//// Extracts the kind of a type description.

import dream_postgres/driver/cell.{type TypeDescription, type TypeKind}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}

/// Gives the `kind` field of the type description.
///
/// ```gleam
/// catalog.describe(type_catalog, connection, type_id, 5000)
/// |> should
/// |> be_ok
/// |> extract_type_kind
/// |> be_equal(Enum(["one"]))
/// |> or_fail_with("Expected an enum")
/// ```
pub fn extract_type_kind(
  result: MatchResult(TypeDescription),
) -> MatchResult(TypeKind) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(description) -> MatchOk(description.kind)
  }
}
