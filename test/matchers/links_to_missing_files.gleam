//// A matcher that finds the repository links at the version of the package
//// whose file is not in the repository (`fixtures/document_links`).

import dream_test/types.{type MatchResult, MatchFailed, MatchOk}
import fixtures/document_links.{type DocumentLinks, type RepositoryLink}
import gleam/list
import simplifile

/// Find the repository links at the version of the package whose path is
/// not a file or a folder of the repository. The chain goes on with those
/// links.
///
/// ## Example
///
/// ```gleam
/// document_links.read()
/// |> should
/// |> be_ok()
/// |> links_to_missing_files()
/// |> be_equal([])
/// |> or_fail_with("Expected every linked file in the repository")
/// ```
pub fn links_to_missing_files(
  result: MatchResult(DocumentLinks),
) -> MatchResult(List(RepositoryLink)) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(links) ->
      MatchOk(
        list.filter(links.repository_links, fn(link) {
          link.ref == links.version && !path_exists(link.path)
        }),
      )
  }
}

fn path_exists(path: String) -> Bool {
  simplifile.is_file(path) == Ok(True)
  || simplifile.is_directory(path) == Ok(True)
}
