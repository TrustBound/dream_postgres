import dream_errors.{type Error}
import dream_postgres.{
  type Connection, type PostgresError, database, default_config, host, password,
  pool_size, port, start, user,
}

/// The pool of the 2.x README, in the 3.0 form. It has no pool name: a
/// name is only for a pool under a supervisor.
pub fn connect_database() -> Result(Connection, Error(PostgresError)) {
  default_config()
  |> host("localhost")
  |> port(5432)
  |> database("myapp")
  |> user("postgres")
  |> password("secret")
  |> pool_size(15)
  |> start
}
