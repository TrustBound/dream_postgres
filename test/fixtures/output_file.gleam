//// The output files of the guides, in `test/outputs/`. Each `text` block
//// of a guide that shows output is a copy of one of these files, and a
//// test compares the file with the real output.

import gleam/int
import gleam/list
import gleam/result
import gleam/string

@external(erlang, "database_ffi", "read_file")
fn read_file(path: String) -> Result(String, Nil)

/// Returns the text of `test/outputs/<name>.txt`, or an empty string when
/// the file cannot be read.
pub fn read(name: String) -> String {
  read_file("test/outputs/" <> name <> ".txt")
  |> result.unwrap("")
}

/// Writes calls and their results as the output blocks show them: the
/// call, then `  -> ` and the result on the next line, a blank line between
/// two calls, and a line break at the end.
pub fn calls(entries: List(#(String, String))) -> String {
  list.map(entries, fn(entry) { entry.0 <> "\n  -> " <> entry.1 })
  |> string.join("\n\n")
  <> "\n"
}

/// Writes `text` with `<a port where nothing listens>` in place of the
/// port `port`, which changes from one test run to the next.
pub fn hide_port(text: String, port: Int) -> String {
  string.replace(
    text,
    ":" <> int.to_string(port) <> "/",
    ":<a port where nothing listens>/",
  )
}
