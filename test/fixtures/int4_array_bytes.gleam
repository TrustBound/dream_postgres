//// The bytes of `int4[]` values in PostgreSQL's binary array format.

/// The array `{1,2}`: one dimension, no NULL, element type 23, two
/// elements from 1, then each element as its length and its bytes.
pub fn one_and_two() -> BitArray {
  <<
    1:size(32), 0:size(32), 23:size(32), 2:size(32), 1:size(32), 4:size(32),
    1:size(32), 4:size(32), 2:size(32),
  >>
}

/// The array `{1,NULL}`: one dimension, with a NULL, element type 23, two
/// elements from 1, then 1 and the NULL length -1.
pub fn one_and_null() -> BitArray {
  <<
    1:size(32), 1:size(32), 23:size(32), 2:size(32), 1:size(32), 4:size(32),
    1:size(32), -1:size(32),
  >>
}

/// The empty array: no dimensions, no NULL, element type 23.
pub fn empty() -> BitArray {
  <<0:size(32), 0:size(32), 23:size(32)>>
}
