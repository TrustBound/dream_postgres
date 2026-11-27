//// A tracer for the tests of the spans (see `driver_test_tracer_ffi.erl`).
//// A test process records its own spans only.

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
