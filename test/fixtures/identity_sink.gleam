//// A sink that passes each event on as it is, for the tests that read the
//// driver's own event types.

import dream_postgres/driver/sink.{type Sink}
import gleam/erlang/process.{type Subject}
import gleam/function.{identity}

/// Returns a sink that sends each event, unchanged, to `subject`.
pub fn identity_sink(subject: Subject(event)) -> Sink(event) {
  sink.to(subject, identity)
}
