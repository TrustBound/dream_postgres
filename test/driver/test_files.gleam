//// Reads the files that the driver tests use (see `driver_file_ffi.erl`).

/// The bytes that a real server sent, from the file `name` in
/// `test/driver/recorded`.
@external(erlang, "driver_file_ffi", "read_recording")
pub fn read_recording(name: String) -> Result(BitArray, String)

/// The DER bytes of the test certificate `name` in
/// `test/fixtures/channel_binding`.
@external(erlang, "driver_file_ffi", "read_certificate")
pub fn read_certificate(name: String) -> Result(BitArray, String)

/// The DER bytes of the first certificate of the PEM file at `path`, or an
/// error text when the file cannot be read or holds no certificate.
@external(erlang, "driver_file_ffi", "read_pem_certificate")
pub fn read_pem_certificate(path: String) -> Result(BitArray, String)
