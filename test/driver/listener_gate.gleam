//// A gate proxy between a listener and a driver server (see
//// `listener_gate_ffi.erl`). While the gate is closed, the proxy closes
//// each new client at once, so the connection stays lost while a test
//// subscribes. It can also cut, answer or keep the first Query after a
//// reconnect. Each command waits until the proxy did it.

/// A running gate proxy.
pub type Gate

/// Starts a gate proxy to the server on `server_port`, with the gate open,
/// and gives the port that the client connects to. Gives the reason when
/// the proxy cannot listen.
@external(erlang, "listener_gate_ffi", "start")
pub fn start_gate(server_port: Int) -> Result(#(Int, Gate), String)

/// Closes the gate and each client's connection, as a broken network does.
@external(erlang, "listener_gate_ffi", "break")
pub fn break_gate(gate: Gate) -> Nil

/// Closes each client's connection and leaves the gate open. The next
/// client passes its login, and the proxy closes it at its first Query, so
/// the first request after the reconnect meets a loss.
@external(erlang, "listener_gate_ffi", "cut_first_query")
pub fn cut_first_query(gate: Gate) -> Nil

/// Closes each client's connection and leaves the gate open, as
/// `cut_first_query` does, but the proxy answers the next client's first
/// Query with `bytes` in place of the server, and the session goes on.
@external(erlang, "listener_gate_ffi", "answer_first_query")
pub fn answer_first_query(gate: Gate, bytes: BitArray) -> Nil

/// Closes each client's connection and leaves the gate open, as
/// `cut_first_query` does, but the proxy keeps the next client's first
/// Query from the server and answers nothing, so the first request after
/// the reconnect gets no answer. The session goes on.
@external(erlang, "listener_gate_ffi", "hold_first_query")
pub fn hold_first_query(gate: Gate) -> Nil

/// Waits until the proxy kept a Query after `hold_first_query`.
@external(erlang, "listener_gate_ffi", "wait_held")
pub fn wait_held(gate: Gate) -> Nil

/// Waits until the closed gate closed a new client, so a reconnect failed.
@external(erlang, "listener_gate_ffi", "wait_refused")
pub fn wait_refused(gate: Gate) -> Nil

/// Opens the gate, so the next client gets a session.
@external(erlang, "listener_gate_ffi", "open")
pub fn open_gate(gate: Gate) -> Nil

/// Closes everything and ends the proxy.
@external(erlang, "listener_gate_ffi", "stop")
pub fn stop_gate(gate: Gate) -> Nil
