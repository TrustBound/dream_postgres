//// The bytes of a NoticeResponse, for a fake server or a proxy that sends
//// one.

import gleam/bit_array

/// A NoticeResponse of severity WARNING with this SQLSTATE code and
/// message.
pub fn warning_notice_bytes(code: String, text: String) -> BitArray {
  let body = <<
    "S", "WARNING":utf8, 0, "V", "WARNING":utf8, 0, "C", code:utf8, 0, "M",
    text:utf8, 0, 0,
  >>
  <<"N":utf8, { bit_array.byte_size(body) + 4 }:32, body:bits>>
}
