//// A sink: where the driver sends its events, and how it converts each
//// event to the message of the receiver.
////
//// A pool, a connection process and a listener send each event through a
//// sink. The sink calls its map function on the event in the driver's
//// process, then sends the result to its subject. So a program gets the
//// driver's events as its own message type, with no process in between.
////
//// The map function must be a plain conversion. It runs in the driver's
//// process, between the driver's own steps. A map that crashes does not
//// stop the driver: the delivery catches the crash, sets the sink's drop
//// flag and gives `MapFailed`. Every copy of the sink shares that flag,
//// so no copy calls the map again: a pool gives copies of the sinks of its
//// connection settings to each connection, also to each one that starts
//// later, and none of them calls a crashed map. The owner of the sink
//// also drops it: a pool or a connection process sets that sink to `None`,
//// and a listener removes the subscription of that sink, the same as when
//// the subscriber's process stops. The driver has no logger, so the drop
//// is the only sign: the receiver gets no more messages from that sink.
////
//// This module is internal to dream_postgres.

import gleam/erlang/process.{type Pid, type Subject}

// Types -----------------------------------------------------------------------

/// Where the driver sends events of the type `event`. Make one with `to`.
pub opaque type Sink(event) {
  Sink(
    /// Maps the event and sends the result to the subject.
    deliver: fn(event) -> Delivery,
    /// The process that owns the subject now.
    owner: fn() -> Result(Pid, Nil),
  )
}

/// What a delivery through a sink did.
pub type Delivery {
  /// The map function converted the event, and the sink sent the result
  /// to its subject.
  Delivered
  /// The map function crashed, now or at an earlier delivery through any
  /// copy of the sink. The sink sent nothing. The owner of the sink must
  /// drop it.
  MapFailed
}

// Making a sink ---------------------------------------------------------------

/// Makes a sink that converts each event with `map`, then sends the
/// result to `subject`. Each copy of the sink shares one drop flag: once
/// `map` crashed, no copy calls it again, in any process.
///
/// `map` must be a plain conversion, for example a wrap in a constructor
/// of the receiver's message type. It runs in the driver's process, so it
/// must not block: a slow map makes the pool, the connection or the
/// listener slow. A map that crashes is dropped: the driver sends nothing
/// to that sink again (see the module documentation).
///
/// ## Parameters
///
/// - `subject`: where each converted event goes
/// - `map`: converts one event to one message of the subject
///
/// ## Returns
///
/// The sink.
pub fn to(subject: Subject(message), map: fn(event) -> message) -> Sink(event) {
  let dropped = new_drop_flag()
  Sink(
    deliver: fn(event) {
      deliver_mapped(dropped, map, send_to(subject, _), event)
    },
    owner: fn() { process.subject_owner(subject) },
  )
}

/// A flag that every copy of a sink shares, set once its map crashed.
type DropFlag

@external(erlang, "dream_postgres_sink_ffi", "new_drop_flag")
fn new_drop_flag() -> DropFlag

fn send_to(subject: Subject(message), message: message) -> Nil {
  process.send(subject, message)
}

/// Calls `map` on the event, catches a crash of it, and sends the result
/// with `send` outside the catch. A crash sets the drop flag, and a sink
/// whose flag is set calls nothing and gives `MapFailed`.
@external(erlang, "dream_postgres_sink_ffi", "deliver")
fn deliver_mapped(
  dropped: DropFlag,
  map: fn(event) -> message,
  send: fn(message) -> Nil,
  event: event,
) -> Delivery

// Delivering ------------------------------------------------------------------

/// Sends one event through the sink.
///
/// ## Parameters
///
/// - `sink`: the sink
/// - `event`: the event to map and send
///
/// ## Returns
///
/// - `Delivered`: the subject got the converted event
/// - `MapFailed`: the map function crashed and the subject got nothing.
///   The caller drops the sink.
@internal
pub fn deliver(sink: Sink(event), event: event) -> Delivery {
  sink.deliver(event)
}

/// The process that owns the sink's subject now, for a monitor of the
/// receiver.
///
/// ## Parameters
///
/// - `sink`: the sink
///
/// ## Returns
///
/// - `Ok(Pid)`: the owner of the subject
/// - `Error(Nil)`: the subject has a name that no process has now
@internal
pub fn owner(sink: Sink(event)) -> Result(Pid, Nil) {
  sink.owner()
}
