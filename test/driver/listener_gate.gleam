//// A gate proxy between a listener and a driver server (see
//// `listener_gate_ffi.erl`). While the gate is closed, the proxy closes
//// each new client at once, so the connection stays lost while a test
//// subscribes. Each command waits until the proxy did it.

/// A running gate proxy.
pub type Gate

/// Starts a gate proxy to the server on `server_port`, with the gate open,
/// and gives the port that the client connects to.
@external(erlang, "listener_gate_ffi", "start")
pub fn start_gate(server_port: Int) -> #(Int, Gate)

/// Closes the gate and each client's connection, as a broken network does.
@external(erlang, "listener_gate_ffi", "break")
pub fn break_gate(gate: Gate) -> Nil

/// Waits until the closed gate closed a new client, so a reconnect failed.
@external(erlang, "listener_gate_ffi", "wait_refused")
pub fn wait_refused(gate: Gate) -> Nil

/// Opens the gate, so the next client gets a session.
@external(erlang, "listener_gate_ffi", "open")
pub fn open_gate(gate: Gate) -> Nil

/// Closes everything and ends the proxy.
@external(erlang, "listener_gate_ffi", "stop")
pub fn stop_gate(gate: Gate) -> Nil
