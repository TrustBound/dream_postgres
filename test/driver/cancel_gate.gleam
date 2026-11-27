//// A cancel gate between a connection and a driver server (see
//// `driver_cancel_gate_ffi.erl`). The gate passes the bytes of the first
//// client, the connection, both ways. It holds each later client, a
//// cancel request, until `release_gate`, so a test decides when a cancel
//// reaches the server. Each command waits until the gate did it.

/// A running cancel gate.
pub type CancelGate

/// What the gate saw, in order, after `record_gate`.
pub type GateEvent {
  /// The connection sent bytes to the server.
  MainBytes
  /// The gate passed the held cancel requests on to the server.
  CancelPassed
}

/// Starts a cancel gate to the server on `server_port`, and gives the port
/// that the client connects to.
@external(erlang, "driver_cancel_gate_ffi", "start")
pub fn start_cancel_gate(server_port: Int) -> #(Int, CancelGate)

/// Starts to note what the gate sees.
@external(erlang, "driver_cancel_gate_ffi", "record")
pub fn record_gate(gate: CancelGate) -> Nil

/// Passes the held cancel requests on to the server.
@external(erlang, "driver_cancel_gate_ffi", "release")
pub fn release_gate(gate: CancelGate) -> Nil

/// What the gate saw since `record_gate`, in order.
@external(erlang, "driver_cancel_gate_ffi", "events")
pub fn gate_events(gate: CancelGate) -> List(GateEvent)

/// Closes every socket of the gate and ends it. The gate also ends by
/// itself when the connection closes; then this does nothing.
@external(erlang, "driver_cancel_gate_ffi", "stop")
pub fn stop_cancel_gate(gate: CancelGate) -> Nil
