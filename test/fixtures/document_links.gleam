//// The links of the documents of the package, for the tests that check them:
//// every link to a file of this repository on GitHub (in README.md, the
//// guides in docs and the doc comments in src), and every relative link of
//// README.md and the guides.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/regexp.{type CompileError, type Match, Match}
import gleam/result
import gleam/string
import simplifile.{type FileError}

/// A link to a file of this repository on GitHub, such as
/// `https://github.com/TrustBound/dream_postgres/blob/3.0.0/LICENSE.md`.
/// `ref` is the tag or branch (`3.0.0`) and `path` is the file (`LICENSE.md`).
pub type RepositoryLink {
  RepositoryLink(file: String, ref: String, path: String)
}

/// A relative link of a document, such as `[codecs](codecs.md#arrays)`.
/// `target` is the path relative to the folder of `file` (empty for a link
/// into the same document) and `anchor` is the part after `#`.
pub type RelativeLink {
  RelativeLink(file: String, target: String, anchor: Option(String))
}

/// The version of the package, from gleam.toml, and the links of its
/// documents.
pub type DocumentLinks {
  DocumentLinks(
    version: String,
    repository_links: List(RepositoryLink),
    relative_links: List(RelativeLink),
  )
}

/// Why the links could not be read.
pub type LinkReadError {
  FileUnreadable(path: String, reason: FileError)
  PatternInvalid(reason: CompileError)
  VersionMissing
}

const repository_link_pattern =
  "https://github\\.com/TrustBound/dream_postgres/blob/([^/\\s]+)/([^)\"#\\s>]+)"

const relative_link_pattern = "\\]\\(([^)#\\s]*)(?:#([^)\\s]+))?\\)"

const version_pattern = "(?m)^version = \"([^\"]+)\""

/// Read the version and every link of README.md, docs and src.
pub fn read() -> Result(DocumentLinks, LinkReadError) {
  use version <- result.try(read_version())
  use documents <- result.try(files_ending_in("docs", ".md"))
  use sources <- result.try(files_ending_in("src", ".gleam"))
  let documents = ["README.md", ..documents]
  use repository_links <- result.try(collect(
    list.append(documents, sources),
    repository_links_of,
  ))
  use relative_links <- result.try(collect(documents, relative_links_of))
  Ok(DocumentLinks(
    version: version,
    repository_links: repository_links,
    relative_links: relative_links,
  ))
}

/// The GitHub anchor of a heading line of a markdown document: the heading
/// text without its `#` marks and HTML tags, in lower case, with spaces as
/// `-` and with every other character than a letter, a digit, `-` or `_`
/// left out.
pub fn heading_anchor(heading: String) -> String {
  heading
  |> drop_heading_marks
  |> drop_tags
  |> string.lowercase
  |> string.to_graphemes
  |> list.filter_map(anchor_character)
  |> string.concat
}

fn drop_heading_marks(heading: String) -> String {
  heading
  |> string.to_graphemes
  |> list.drop_while(fn(character) { character == "#" })
  |> string.concat
  |> string.drop_start(1)
}

fn drop_tags(text: String) -> String {
  case string.split(text, "<") {
    [before_first_tag, ..pieces] ->
      before_first_tag <> string.concat(list.map(pieces, after_tag))
    [] -> text
  }
}

fn after_tag(piece: String) -> String {
  case string.split_once(piece, ">") {
    Ok(#(_tag, after)) -> after
    Error(Nil) -> "<" <> piece
  }
}

fn anchor_character(character: String) -> Result(String, Nil) {
  case character {
    " " -> Ok("-")
    "-" | "_" -> Ok(character)
    _ -> keep_letter_or_digit(character)
  }
}

fn keep_letter_or_digit(character: String) -> Result(String, Nil) {
  case string.contains("abcdefghijklmnopqrstuvwxyz0123456789", character) {
    True -> Ok(character)
    False -> Error(Nil)
  }
}

fn read_version() -> Result(String, LinkReadError) {
  use content <- result.try(read_file("gleam.toml"))
  use pattern <- result.try(compile(version_pattern))
  case regexp.scan(with: pattern, content: content) {
    [Match(submatches: [Some(version)], ..), ..] -> Ok(version)
    _ -> Error(VersionMissing)
  }
}

fn files_ending_in(
  folder: String,
  extension: String,
) -> Result(List(String), LinkReadError) {
  simplifile.get_files(in: folder)
  |> result.map_error(FileUnreadable(folder, _))
  |> result.map(list.filter(_, string.ends_with(_, extension)))
  |> result.map(list.sort(_, string.compare))
}

fn collect(
  files: List(String),
  links_of: fn(String, String) -> Result(List(link), LinkReadError),
) -> Result(List(link), LinkReadError) {
  files
  |> list.try_map(fn(file) {
    use content <- result.try(read_file(file))
    links_of(file, content)
  })
  |> result.map(list.flatten)
}

fn repository_links_of(
  file: String,
  content: String,
) -> Result(List(RepositoryLink), LinkReadError) {
  use pattern <- result.try(compile(repository_link_pattern))
  regexp.scan(with: pattern, content: content)
  |> list.filter_map(fn(found) { repository_link(file, found) })
  |> Ok
}

fn repository_link(file: String, found: Match) -> Result(RepositoryLink, Nil) {
  case found.submatches {
    [Some(ref), Some(path)] -> Ok(RepositoryLink(file:, ref:, path:))
    _ -> Error(Nil)
  }
}

fn relative_links_of(
  file: String,
  content: String,
) -> Result(List(RelativeLink), LinkReadError) {
  use pattern <- result.try(compile(relative_link_pattern))
  regexp.scan(with: pattern, content: content)
  |> list.filter_map(fn(found) { relative_link(file, found) })
  |> list.filter(fn(link) { !string.contains(link.target, "://") })
  |> Ok
}

fn relative_link(file: String, found: Match) -> Result(RelativeLink, Nil) {
  case found.submatches {
    [Some(target), Some(anchor)] ->
      Ok(RelativeLink(file:, target:, anchor: Some(anchor)))
    [Some(target)] -> Ok(RelativeLink(file:, target:, anchor: None))
    [None, Some(anchor)] ->
      Ok(RelativeLink(file:, target: "", anchor: Some(anchor)))
    _ -> Error(Nil)
  }
}

fn read_file(path: String) -> Result(String, LinkReadError) {
  simplifile.read(from: path) |> result.map_error(FileUnreadable(path, _))
}

fn compile(pattern: String) -> Result(regexp.Regexp, LinkReadError) {
  regexp.from_string(pattern) |> result.map_error(PatternInvalid)
}
