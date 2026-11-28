//// A tracer for the tests of the spans (see `driver_test_tracer_ffi.erl`).
//// A test process records its own spans only.

import gleam/list

/// A span that the calling process started and ended.
pub type RecordedSpan {
  RecordedSpan(
    name: String,
    /// The span kind, for example `client`.
    kind: String,
    /// Each attribute with its value as text, sorted by key.
    attributes: List(#(String, String)),
    /// The span's status is Error.
    failed: Bool,
  )
}

/// Makes the test tracer the default tracer of the OpenTelemetry API.
@external(erlang, "driver_test_tracer_ffi", "install")
pub fn install_test_tracer() -> Nil

/// Records the spans of the calling process from now on.
@external(erlang, "driver_test_tracer_ffi", "record_spans_here")
pub fn record_spans_here() -> Nil

/// The next span that the calling process ended.
@external(erlang, "driver_test_tracer_ffi", "next_span")
pub fn next_span() -> Result(RecordedSpan, String)

/// Records the spans of every process, sent to the calling process, until
/// `stop_recording_every_process`: for a test of the driver's own
/// processes. Only one test at a time may do it.
@external(erlang, "driver_test_tracer_ffi", "record_every_process_here")
pub fn record_every_process_here() -> Nil

/// Ends `record_every_process_here`.
@external(erlang, "driver_test_tracer_ffi", "stop_recording_every_process")
pub fn stop_recording_every_process() -> Nil

/// Every span that the calling process got by now, in the order they
/// started. It never waits.
@external(erlang, "driver_test_tracer_ffi", "spans_now")
pub fn spans_now() -> List(RecordedSpan)

/// The spans whose `server.port` is one of `ports`, in their order: the
/// spans of the connections of one test, when each has its own port.
pub fn spans_on_ports(
  spans: List(RecordedSpan),
  ports: List(String),
) -> List(RecordedSpan) {
  list.filter(spans, fn(span) {
    list.any(span.attributes, fn(attribute) {
      attribute.0 == "server.port" && list.contains(ports, attribute.1)
    })
  })
}
