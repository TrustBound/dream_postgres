import dream_errors.{type Error}
import dream_postgres/config.{
  TlsOff, database, default_config, host, password, pool_size, port, tls, user,
}
import dream_postgres/error.{type PostgresError}
import dream_postgres/pool.{type Connection, start_pool}

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
  |> start_pool
}
