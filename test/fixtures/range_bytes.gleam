//// The bytes of int4 ranges and multiranges in PostgreSQL's binary format.

/// The bytes of one int4 bound of a range: its length, 4, then the value.
///
/// ## Example
///
/// ```gleam
/// <<2, range_bytes.int4_bound(1):bits, range_bytes.int4_bound(5):bits>>
/// ```
pub fn int4_bound(value: Int) -> BitArray {
  <<4:size(32), value:size(32)>>
}

/// The bytes of the int4 multirange `{[1,3),[5,7)}`.
///
/// ## Example
///
/// ```gleam
/// Binary(range_bytes.two_int4_ranges())
/// ```
pub fn two_int4_ranges() -> BitArray {
  let first = <<2, int4_bound(1):bits, int4_bound(3):bits>>
  let second = <<2, int4_bound(5):bits, int4_bound(7):bits>>
  <<2:size(32), 17:size(32), first:bits, 17:size(32), second:bits>>
}
