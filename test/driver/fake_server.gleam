//// Fake servers on localhost (see `driver_fake_server_ffi.erl`), for the
//// tests of servers that refuse or misbehave, and a free port with no
//// listener.

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
