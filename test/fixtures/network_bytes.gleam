//// The bytes of network values in PostgreSQL's binary formats.

/// The 16 bytes of the IPv6 address `2001:db8::1`.
///
/// ## Example
///
/// ```gleam
/// Binary(<<3, 128, 0, 16, network_bytes.ipv6_address():bits>>)
/// ```
pub fn ipv6_address() -> BitArray {
  <<
    0x2001:size(16), 0x0db8:size(16), 0:size(16), 0:size(16), 0:size(16),
    0:size(16), 0:size(16), 1:size(16),
  >>
}
