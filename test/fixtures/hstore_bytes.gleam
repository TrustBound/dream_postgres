//// The bytes of hstore values in the binary format of the hstore extension.

/// The bytes of the hstore `"a"=>"b"`.
///
/// ## Example
///
/// ```gleam
/// Binary(hstore_bytes.one_pair())
/// ```
pub fn one_pair() -> BitArray {
  <<1:size(32), 1:size(32), "a":utf8, 1:size(32), "b":utf8>>
}

/// The bytes of the hstore `"a"=>NULL`.
///
/// ## Example
///
/// ```gleam
/// Binary(hstore_bytes.null_pair())
/// ```
pub fn null_pair() -> BitArray {
  <<1:size(32), 1:size(32), "a":utf8, -1:size(32)>>
}
