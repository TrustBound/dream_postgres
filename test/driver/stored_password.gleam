//// A password that a test keeps in its own process (see
//// `driver_stored_password_ffi.erl`), for the password functions that
//// read it each time the server asks.

/// Keeps `value` under `key` in the caller's process.
@external(erlang, "driver_stored_password_ffi", "store")
pub fn store_password(key: String, value: String) -> Nil

/// The value that the caller's process keeps under `key`. A test stores it
/// first.
@external(erlang, "driver_stored_password_ffi", "stored")
pub fn stored_password(key: String) -> String
