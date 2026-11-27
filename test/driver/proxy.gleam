//// A test proxy between a connection process and a driver server (see
//// `driver_proxy_ffi.erl`). A test uses it to break the connection on
//// purpose: it closes or resets the client socket, answers the client in
//// place of the server, stops listening, or sends the client bytes as if
//// the server sent them.

/// A running proxy.
pub type Proxy

/// A watch on the client side of a proxy, made before the client ends.
pub type ClientEndWatch

/// Starts a proxy to the server on `server_port`, and gives the port that
/// the client connects to.
@external(erlang, "driver_proxy_ffi", "start")
pub fn start_proxy(server_port: Int) -> #(Int, Proxy)

/// Sends `bytes` to the client as if the server sent them.
@external(erlang, "driver_proxy_ffi", "inject")
pub fn inject(proxy: Proxy, bytes: BitArray) -> Nil

/// Closes the client socket, as a network close.
@external(erlang, "driver_proxy_ffi", "close_client")
pub fn close_client(proxy: Proxy) -> Nil

/// Resets the client socket, as a network reset.
@external(erlang, "driver_proxy_ffi", "reset_client")
pub fn reset_client(proxy: Proxy) -> Nil

/// Keeps the next bytes from the client away from the server, answers them
/// with `bytes`, and then reads nothing more from the client, so the
/// client's send queue fills.
@external(erlang, "driver_proxy_ffi", "answer_next_request")
pub fn answer_next_request(proxy: Proxy, bytes: BitArray) -> Nil

/// Closes the listening socket, so a new connect to the proxy is refused,
/// and the session goes on.
@external(erlang, "driver_proxy_ffi", "stop_listening")
pub fn stop_listening(proxy: Proxy) -> Nil

/// Starts to watch for the end of the client.
@external(erlang, "driver_proxy_ffi", "watch_client_end")
pub fn watch_client_end(proxy: Proxy) -> ClientEndWatch

/// Waits for the client to close, and gives the last bytes it sent.
@external(erlang, "driver_proxy_ffi", "client_end")
pub fn client_end(watch: ClientEndWatch) -> BitArray
