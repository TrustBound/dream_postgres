import dream_errors.{type Error}
import dream_postgres/config.{
  database, default_config, host, password, pool_size, port, user,
}
import dream_postgres/error.{type PostgresError}
import dream_postgres/pool.{type Connection, start}

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
