//// A matcher that finds the repository links whose ref is not the version
//// of the package (`fixtures/document_links`).

import dream_test/types.{type MatchResult, MatchFailed, MatchOk}
import fixtures/document_links.{type DocumentLinks, type RepositoryLink}
import gleam/list

/// Find the repository links whose ref is not the version of the package,
/// outside the document `except_file`. The chain goes on with those links.
///
/// ## Example
///
/// ```gleam
/// document_links.read()
/// |> should
/// |> be_ok()
/// |> links_off_version(except_file: "docs/guides/upgrading-to-3.md")
/// |> be_equal([])
/// |> or_fail_with("Expected every link at the package version")
/// ```
pub fn links_off_version(
  result: MatchResult(DocumentLinks),
  except_file except_file: String,
) -> MatchResult(List(RepositoryLink)) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(links) ->
      MatchOk(
        list.filter(links.repository_links, fn(link) {
          link.file != except_file && link.ref != links.version
        }),
      )
  }
}
