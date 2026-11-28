//// A matcher that finds the relative links whose document or heading is
//// not there (`fixtures/document_links`).

import dream_test/types.{type MatchResult, MatchFailed, MatchOk}
import fixtures/document_links.{
  type DocumentLinks, type RelativeLink, heading_anchor,
}
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import simplifile

/// Find the relative links whose target document cannot be read, or whose
/// anchor is not the anchor of a heading of that document. The chain goes
/// on with those links.
///
/// ## Example
///
/// ```gleam
/// document_links.read()
/// |> should
/// |> be_ok()
/// |> relative_links_to_missing_targets()
/// |> be_equal([])
/// |> or_fail_with("Expected every relative link to reach its heading")
/// ```
pub fn relative_links_to_missing_targets(
  result: MatchResult(DocumentLinks),
) -> MatchResult(List(RelativeLink)) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(links) ->
      MatchOk(list.filter(links.relative_links, fn(link) { !reaches(link) }))
  }
}

fn reaches(link: RelativeLink) -> Bool {
  let path = target_path(link)
  case simplifile.read(from: path), link.anchor {
    Error(_), _ -> False
    Ok(_), None -> True
    Ok(content), Some(anchor) -> list.contains(anchors_of(content), anchor)
  }
}

fn target_path(link: RelativeLink) -> String {
  case link.target {
    "" -> link.file
    target -> folder_of(link.file) <> target
  }
}

fn folder_of(file: String) -> String {
  case string.split(file, "/") |> list.reverse {
    [_document, ..folders] ->
      list.reverse(folders)
      |> list.map(fn(folder) { folder <> "/" })
      |> string.concat
    [] -> ""
  }
}

fn anchors_of(content: String) -> List(String) {
  content
  |> string.split("\n")
  |> list.filter(string.starts_with(_, "#"))
  |> list.map(heading_anchor)
}
