//// The bytes of the messages that a login sends, written out from the
//// layouts of the PostgreSQL documentation, chapter "Frontend/Backend
//// Protocol", section "Message Formats", for the tests to compare with
//// `login.encode_login_message`.

import gleam/bit_array.{byte_size}
import gleam/list.{map}

/// The bytes of a StartupMessage of protocol 3.`minor_version`: the
/// length, the version, `user` and each parameter with its zero bytes,
/// then a zero byte.
pub fn startup_message_bytes(
  minor_version: Int,
  user: String,
  parameters: List(#(String, String)),
) -> BitArray {
  let pairs =
    bit_array.concat(map([#("user", user), ..parameters], parameter_bytes))
  let body = <<3:16, minor_version:16, pairs:bits, 0>>
  let length = byte_size(body) + 4
  <<length:32, body:bits>>
}

fn parameter_bytes(parameter: #(String, String)) -> BitArray {
  <<parameter.0:utf8, 0, parameter.1:utf8, 0>>
}

/// The bytes of a PasswordMessage: `p`, the length, the password and its
/// zero byte.
pub fn password_message_bytes(password: String) -> BitArray {
  let body = <<password:utf8, 0>>
  let length = byte_size(body) + 4
  <<"p", length:32, body:bits>>
}

/// The bytes of a SASLInitialResponse: `p`, the length, the mechanism and
/// its zero byte, the length of the data, the data.
pub fn sasl_initial_response_bytes(
  mechanism: String,
  data: BitArray,
) -> BitArray {
  let data_length = byte_size(data)
  let body = <<mechanism:utf8, 0, data_length:32, data:bits>>
  let length = byte_size(body) + 4
  <<"p", length:32, body:bits>>
}

/// The bytes of a SASLResponse: `p`, the length, the data.
pub fn sasl_response_bytes(data: BitArray) -> BitArray {
  let length = byte_size(data) + 4
  <<"p", length:32, data:bits>>
}
