//// The Gleam value of PostgreSQL's range and multirange types, for any
//// element type: `int4range`, `daterange`, `tstzrange` and a range type
//// that an app makes.

/// One end of a range.
pub type Bound(a) {
  /// No limit on this side.
  Unbounded
  /// The range holds this value.
  Inclusive(a)
  /// The range stops just before this value.
  Exclusive(a)
}

/// A range: empty, or the values between two bounds.
pub type Range(a) {
  EmptyRange
  Range(lower: Bound(a), upper: Bound(a))
}
