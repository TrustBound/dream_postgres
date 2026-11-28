//// A matcher that gives the text of the UUID of the chain.

import dream_test/types.{type MatchResult, MatchFailed, MatchOk}
import dream_uuid.{type Uuid}

/// Give the text of the UUID: lower case hex in the 8-4-4-4-12 form. The
/// chain goes on with the text.
///
/// ## Example
///
/// ```gleam
/// dream_uuid.from_string("A0EEBC99-9C0B-4EF8-BB6D-6BB9BD380A11")
/// |> should
/// |> be_ok()
/// |> have_uuid_text()
/// |> be_equal("a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11")
/// |> or_fail_with("Expected the lower case text")
/// ```
pub fn have_uuid_text(result: MatchResult(Uuid)) -> MatchResult(String) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(value) -> MatchOk(dream_uuid.to_string(value))
  }
}
