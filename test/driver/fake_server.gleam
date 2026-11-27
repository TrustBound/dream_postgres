//// Fake servers on localhost (see `driver_fake_server_ffi.erl`), for the
//// tests of servers that refuse or misbehave, and a free port with no
//// listener.

import gleam/dynamic.{type Dynamic}
import gleam/erlang/process
import gleam/result

/// A running fake server.
pub type FakeServer

/// What the fake server does after the first 8 bytes of the client (the
/// SSLRequest or the start of the StartupMessage).
pub type FakeBehavior {
  /// Sends these bytes.
  Answer(BitArray)
  /// Resets the connection.
  Reset
  /// Answers `S`, then sends bytes that are not TLS.
  NotTls
  /// Answers `S` and does a TLS handshake with this certificate and key.
  Tls(String, String)
}

/// Starts a fake server, and gives its port. Gives the reason when the
/// server cannot listen.
@external(erlang, "driver_fake_server_ffi", "start")
pub fn start_fake_server(
  behavior: FakeBehavior,
) -> Result(#(Int, FakeServer), String)

/// Waits for the fake server to finish with its first client, and says
/// whether that client closed the connection. Gives the reason when a step
/// of the server failed.
@external(erlang, "driver_fake_server_ffi", "client_closed")
pub fn client_closed(server: FakeServer) -> Result(Bool, String)

/// Starts a server that accepts a connection and never answers, and gives
/// its port.
@external(erlang, "driver_fake_server_ffi", "start_silent")
pub fn start_silent_server() -> Result(Int, String)

/// Starts a server that accepts a connection, sends `bytes` at once, and
/// never reads from it, so the client's sends block once the buffers are
/// full. Gives its port.
@external(erlang, "driver_fake_server_ffi", "start_deaf")
pub fn start_deaf_server(bytes: BitArray) -> Result(Int, String)

/// The next message of a TCP or TLS socket of the calling process, for a
/// test that reads a socket message itself while other messages, such as
/// the fake server's own report, may come first.
@external(erlang, "driver_fake_server_ffi", "next_socket_message")
pub fn next_socket_message() -> Result(Dynamic, String)

/// Starts a server that accepts a connection, sends `bytes` at once, and
/// never reads from it, as `start_deaf_server` does. Once the client's
/// socket gets a PasswordMessage to send, which waits behind the full
/// queue, the server resets the connection. Gives its port.
@external(erlang, "driver_fake_server_ffi", "start_deaf_then_reset")
pub fn start_deaf_then_reset_server(bytes: BitArray) -> Result(Int, String)

/// A server that answers `S`, does a TLS handshake with this certificate
/// and key, and waits for `send_bad_record`.
pub type BadRecordServer

/// Starts a server that does a TLS handshake and then waits, and gives its
/// port.
@external(erlang, "driver_fake_server_ffi", "start_tls_then_bad_record")
pub fn start_tls_then_bad_record(
  certificate_file: String,
  key_file: String,
) -> Result(#(Int, BadRecordServer), String)

/// Makes the server send a record that no key of the TLS session protects,
/// so the client's TLS layer raises an alert.
@external(erlang, "driver_fake_server_ffi", "send_bad_record")
pub fn send_bad_record(server: BadRecordServer) -> Result(Nil, String)

/// The next message of the calling process, of any kind, for a test that
/// reads a socket message itself.
pub fn next_message() -> Result(Dynamic, String) {
  process.new_selector()
  |> process.select_other(fn(message) { message })
  |> process.selector_receive(5000)
  |> result.replace_error("no message within 5 seconds")
}

/// A port on localhost with no listener.
@external(erlang, "port_ffi", "free_port")
pub fn free_port() -> Int

/// Starts a fake server on a free port of localhost that reads the
/// StartupMessage of its one client and answers with the FATAL
/// ErrorResponse 28P01. `client_closed` then tells whether the client
/// closed its socket.
@external(erlang, "driver_parity_ffi", "start_login_refusing_server")
pub fn start_login_refusing_server() -> Result(#(Int, FakeServer), String)

/// Starts a fake server on a free port of localhost that reads the
/// SSLRequest of its one client and then closes its sending side.
/// `client_closed` then tells whether the client closed its socket.
@external(erlang, "driver_parity_ffi", "start_closing_server")
pub fn start_closing_server() -> Result(#(Int, FakeServer), String)
