//// The errno names that OTP 28 and OTP 29 know, from the copies of their
//// lists in test/fixtures/otp.

import gleam/list
import gleam/result
import gleam/string
import simplifile

/// The errno names of OTP 28 and OTP 29 in sorted order, less "unknown"
/// (the name for an errno that OTP 28 does not know) and "esuccess"
/// (success, not an error).
///
/// ## Example
///
/// ```gleam
/// otp_errno_names.sorted()
/// // -> ["e2big", "eacces", ...]
/// ```
pub fn sorted() -> List(String) {
  list.append(
    names_in("test/fixtures/otp/erl_posix_str-OTP-28.5.0.9.txt"),
    names_in("test/fixtures/otp/erl_errno_str-OTP-29.1.2.txt"),
  )
  |> list.unique
  |> list.filter(fn(name) { name != "unknown" && name != "esuccess" })
  |> list.sort(string.compare)
}

fn names_in(path: String) -> List(String) {
  simplifile.read(path)
  |> result.unwrap("")
  |> string.split("\n")
  |> list.filter(fn(line) { line != "" && !string.starts_with(line, "#") })
}
