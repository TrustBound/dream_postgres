//// Ports and database URLs that nothing listens on, for the tests that
//// start a pool.

import gleam/int

@external(erlang, "port_ffi", "free_port")
fn free_port() -> Int

/// Returns a TCP port on 127.0.0.1 that has no listener.
///
/// Each call gives a port that no other test in this run got, so tests that
/// run at the same time do not share a port. A pool that starts on this
/// port never connects, and each query on it returns
/// `Error(pog.ConnectionUnavailable)`.
pub fn unused_port() -> Int {
  free_port()
}

/// Returns a PostgreSQL URL for a database on `unused_port()`.
pub fn unused_database_url() -> String {
  "postgresql://user:pass@127.0.0.1:"
  <> int.to_string(unused_port())
  <> "/myapp"
}
