//// Paths of recording files for the tests, each one used by one recorder
//// only.

import gleam/bit_array
import gleam/erlang/reference
import gleam/string

/// A path in `directory` that no other call gives: `<name>_<unique>.json`.
///
/// ## Example
///
/// ```gleam
/// recording_paths.unique(in: "build/no_database_recordings", name: "empty")
/// // -> "build/no_database_recordings/empty_2F2F65...json"
/// ```
pub fn unique(in directory: String, name name: String) -> String {
  let unique_text =
    bit_array.base16_encode(<<string.inspect(reference.new()):utf8>>)
  directory <> "/" <> name <> "_" <> unique_text <> ".json"
}
