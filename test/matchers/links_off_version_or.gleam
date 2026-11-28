//// A matcher that finds the repository links of one document whose ref is
//// neither the version of the package nor one older version
//// (`fixtures/document_links`).

import dream_test/types.{type MatchResult, MatchFailed, MatchOk}
import fixtures/document_links.{type DocumentLinks, type RepositoryLink}
import gleam/list

/// Find the repository links of the document `file` whose ref is neither
/// the version of the package nor `older`. The chain goes on with those
/// links.
///
/// ## Example
///
/// ```gleam
/// document_links.read()
/// |> should
/// |> be_ok()
/// |> links_off_version_or(file: "docs/guides/upgrading-to-3.md", older: "2.0.0")
/// |> be_equal([])
/// |> or_fail_with("Expected links at the package version or at 2.0.0")
/// ```
pub fn links_off_version_or(
  result: MatchResult(DocumentLinks),
  file file: String,
  older older: String,
) -> MatchResult(List(RepositoryLink)) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(links) ->
      MatchOk(
        list.filter(links.repository_links, fn(link) {
          link.file == file && link.ref != links.version && link.ref != older
        }),
      )
  }
}
