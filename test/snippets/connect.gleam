import dream_errors.{type Error}
import dream_postgres.{
  type Connection, type PostgresError, TlsOff, database, default_config, host,
  password, pool_size, port, start, tls, user,
}

/// Starts a pool of 4 connections to the database `dream_test` on this
/// machine. The local test server has no certificate, so TLS is off.
pub fn connect(port_number: Int) -> Result(Connection, Error(PostgresError)) {
  default_config()
  |> host("localhost")
  |> port(port_number)
  |> database("dream_test")
  |> user("dream")
  |> password("dream")
  |> pool_size(4)
  |> tls(TlsOff)
  |> start
}
