//// A test proxy between a connection process and a driver server (see
//// `driver_proxy_ffi.erl`). A test uses it to break the connection on
//// purpose: it closes or resets the client socket, stops reading, or sends
//// the client bytes as if the server sent them.

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

/// Stops reading from the client, so the client's send queue fills.
@external(erlang, "driver_proxy_ffi", "stop_reading")
pub fn stop_reading(proxy: Proxy) -> Nil

/// Starts to watch for the end of the client.
@external(erlang, "driver_proxy_ffi", "watch_client_end")
pub fn watch_client_end(proxy: Proxy) -> ClientEndWatch

/// Waits for the client to close, and gives the last bytes it sent.
@external(erlang, "driver_proxy_ffi", "client_end")
pub fn client_end(watch: ClientEndWatch) -> BitArray

/// Ends the proxy and closes its sockets, so the server ends the session
/// also after `stop_reading`. A test stops each proxy that it starts.
@external(erlang, "driver_proxy_ffi", "stop")
pub fn stop_proxy(proxy: Proxy) -> Nil
