//// Reads the files that the driver tests use (see `driver_file_ffi.erl`).

/// The bytes that a real server sent, from the file `name` in
/// `test/driver/recorded`.
@external(erlang, "driver_file_ffi", "read_recording")
pub fn read_recording(name: String) -> Result(BitArray, String)
