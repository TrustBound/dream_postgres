//// The named codes of the errcodes.txt file of each supported PostgreSQL
//// version, from the copies under test/fixtures/errcodes.

import gleam/list
import gleam/result
import gleam/string
import simplifile

/// Each code of the errcodes.txt file of PostgreSQL `version` that has a
/// condition name, as `#(code, condition_name)`. A line of the file is
/// code, severity, macro and name; a line with no name is a second macro
/// for a named code, and is not in the list.
///
/// ## Example
///
/// ```gleam
/// errcodes.named_codes("16")
/// // -> [#("00000", "successful_completion"), ..]
/// ```
pub fn named_codes(version: String) -> List(#(String, String)) {
  let path = "test/fixtures/errcodes/postgresql-" <> version <> ".txt"
  let text = simplifile.read(path) |> result.unwrap("")
  string.split(text, "\n")
  |> list.filter_map(named_code)
}

fn named_code(line: String) -> Result(#(String, String), Nil) {
  case string.split(line, " ") |> list.filter(fn(part) { part != "" }) {
    [code, _severity, "ERRCODE_" <> _, name] -> Ok(#(code, name))
    _ -> Error(Nil)
  }
}
