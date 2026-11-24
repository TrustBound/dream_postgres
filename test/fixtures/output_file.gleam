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

/// Returns the block of `test/outputs/<name>.txt` for the call `call`, as
/// `calls` writes one call: the call, then `  -> ` and the result on the
/// next line, and a line break at the end. Returns an empty string when the
/// file has no block for `call`. A test of one call compares its output with
/// this block, so a slow call does not wait for the other calls of the file.
pub fn block(name: String, call: String) -> String {
  blocks(read(name))
  |> list.find(fn(block) { string.starts_with(block, call <> "\n  -> ") })
  |> result.map(fn(block) { block <> "\n" })
  |> result.unwrap("")
}

/// Returns the calls of `test/outputs/<name>.txt`, in the order of the
/// file. A test compares them with the calls of the tests of the file, so
/// that the file shows no call that a test does not run.
pub fn call_lines(name: String) -> List(String) {
  blocks(read(name))
  |> list.map(fn(block) {
    string.split_once(block, "\n")
    |> result.map(fn(pair) { pair.0 })
    |> result.unwrap(block)
  })
}

fn blocks(text: String) -> List(String) {
  string.trim_end(text)
  |> string.split("\n\n")
}
