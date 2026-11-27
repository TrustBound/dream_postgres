//// The bytes of `float8` values in PostgreSQL's binary format, for the
//// geometric values that are built from them.

import gleam/list

/// The `float8` NaN, as eight bytes.
pub const not_a_number = <<0x7FF8000000000000:size(64)>>

/// The `float8` Infinity, as eight bytes.
pub const positive_infinity = <<0x7FF0000000000000:size(64)>>

/// The `float8` -Infinity, as eight bytes.
pub const negative_infinity = <<0xFFF0000000000000:size(64)>>

/// The values as `float8` values, eight bytes each, in order.
///
/// ## Example
///
/// ```gleam
/// float_bytes.float8_values([1.0, -1.0])
/// // -> <<1.0:float-size(64), -1.0:float-size(64)>>
/// ```
pub fn float8_values(values: List(Float)) -> BitArray {
  list.fold(values, <<>>, fn(bytes, value) {
    <<bytes:bits, value:float-size(64)>>
  })
}
