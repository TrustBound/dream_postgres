//// Ports on localhost with no listener, for tests of a server that is
//// down.

/// A port on localhost that nothing listens on now.
@external(erlang, "port_ffi", "free_port")
pub fn free_port() -> Int
