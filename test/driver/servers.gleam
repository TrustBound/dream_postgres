//// The driver servers of `docker-compose.yml`: one for each supported
//// PostgreSQL version. `make db-up` starts them. Every driver test that
//// needs a server runs on each of them.

/// One driver server.
pub type Server {
  Server(
    /// The PostgreSQL major version, for example `16`.
    version: Int,
    /// The port on localhost.
    port: Int,
  )
}

/// The first driver server, PostgreSQL 16. A test that needs one server,
/// not each of them, uses it.
pub const first_driver_server = Server(version: 16, port: 5441)

/// The four driver servers, PostgreSQL 16 to 19.
pub fn driver_servers() -> List(Server) {
  [
    first_driver_server,
    Server(version: 17, port: 5442),
    Server(version: 18, port: 5443),
    Server(version: 19, port: 5444),
  ]
}

/// The password of every database user of the driver servers.
pub const password = "dream"

/// The database of the driver servers.
pub const database = "dream_test"
