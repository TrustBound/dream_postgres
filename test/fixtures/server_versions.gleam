//// The PostgreSQL versions of the driver servers (`driver/servers`), for
//// the suites that have one group of tests for each server.

import driver/servers.{driver_servers}
import gleam/int
import gleam/list

/// The version of each driver server, lowest first.
///
/// ## Example
///
/// ```gleam
/// server_versions.all()
/// // -> [16, 17, 18, 19]
/// ```
pub fn all() -> List(Int) {
  list.map(driver_servers(), fn(server) { server.version })
}

/// The versions of the driver servers that are `lowest` or later.
///
/// ## Example
///
/// ```gleam
/// server_versions.from(17)
/// // -> [17, 18, 19]
/// ```
pub fn from(lowest: Int) -> List(Int) {
  list.filter(all(), fn(version) { version >= lowest })
}

/// The name of the group of tests for one version.
///
/// ## Example
///
/// ```gleam
/// server_versions.group_name(16)
/// // -> "PostgreSQL 16"
/// ```
pub fn group_name(version: Int) -> String {
  "PostgreSQL " <> int.to_string(version)
}
