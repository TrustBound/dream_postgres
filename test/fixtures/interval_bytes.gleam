//// The bytes of the infinite intervals of PostgreSQL 17 and later.

/// The bytes of the interval `infinity`: the largest microseconds, days and
/// months.
///
/// ## Example
///
/// ```gleam
/// Binary(interval_bytes.infinite())
/// ```
pub fn infinite() -> BitArray {
  <<
    9_223_372_036_854_775_807:size(64),
    2_147_483_647:size(32),
    2_147_483_647:size(32),
  >>
}

/// The bytes of the interval `-infinity`: the smallest microseconds, days
/// and months.
///
/// ## Example
///
/// ```gleam
/// Binary(interval_bytes.negative_infinite())
/// ```
pub fn negative_infinite() -> BitArray {
  <<
    -9_223_372_036_854_775_808:size(64),
    -2_147_483_648:size(32),
    -2_147_483_648:size(32),
  >>
}
