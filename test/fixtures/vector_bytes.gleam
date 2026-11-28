//// The bytes of pgvector values in the binary formats of the extension.

/// The bytes of the vector `[1.5,-2]`.
///
/// ## Example
///
/// ```gleam
/// Binary(vector_bytes.vector_of_two())
/// ```
pub fn vector_of_two() -> BitArray {
  <<2:size(16), 0:size(16), 0x3FC00000:size(32), 0xC0000000:size(32)>>
}

/// The bytes of the half vector `[1.5,-2]`.
///
/// ## Example
///
/// ```gleam
/// Binary(vector_bytes.half_vector_of_two())
/// ```
pub fn half_vector_of_two() -> BitArray {
  <<2:size(16), 0:size(16), 0x3E00:size(16), 0xC000:size(16)>>
}

/// The bytes of the sparse vector `{1:1.5,4:-2}/5`: 1.5 at index 0 and -2
/// at index 3, of 5 dimensions.
///
/// ## Example
///
/// ```gleam
/// Binary(vector_bytes.sparse_vector_of_two())
/// ```
pub fn sparse_vector_of_two() -> BitArray {
  <<
    5:size(32),
    2:size(32),
    0:size(32),
    0:size(32),
    3:size(32),
    0x3FC00000:size(32),
    0xC0000000:size(32),
  >>
}
