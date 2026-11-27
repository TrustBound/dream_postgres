//// Startup parameters whose StartupMessage is too long for its length
//// field, built with little memory: every value is the same text of
//// 1 MiB, so all the parameters share its bytes. 2048 values of 1 MiB
//// are 2 GiB, more than the 2147483647 bytes that the field can count.

import gleam/int
import gleam/list.{index_map}
import gleam/string.{repeat}

/// The bytes of the value that every parameter shares.
pub const value_bytes = 1_048_576

/// The number of parameters.
pub const parameter_count = 2048

/// The parameters `p0` to `p2047`, each with the same value of
/// `value_bytes` bytes.
pub fn long_startup_parameters() -> List(#(String, String)) {
  let value = repeat("x", value_bytes)
  list.repeat(value, parameter_count) |> index_map(numbered_parameter)
}

fn numbered_parameter(value: String, index: Int) -> #(String, String) {
  #("p" <> int.to_string(index), value)
}
