//// A matcher that counts the relative links (`fixtures/document_links`).

import dream_test/types.{type MatchResult, MatchFailed, MatchOk}
import fixtures/document_links.{type DocumentLinks}
import gleam/list

/// Count the relative links. The chain goes on with the count.
///
/// ## Example
///
/// ```gleam
/// document_links.read()
/// |> should
/// |> be_ok()
/// |> count_relative_links()
/// |> be_greater_than(0)
/// |> or_fail_with("Expected the guides to have relative links")
/// ```
pub fn count_relative_links(
  result: MatchResult(DocumentLinks),
) -> MatchResult(Int) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(links) -> MatchOk(list.length(links.relative_links))
  }
}
