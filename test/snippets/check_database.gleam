import dream_errors.{type Error}
import dream_postgres/boot_check.{verify_queries}
import dream_postgres/error.{type PostgresError}
import dream_postgres/pool.{type Connection}
import snippets/user_checks.{queries}

/// Checks each query of the app against the database, at boot.
pub fn check_database(
  connection: Connection,
) -> Result(Nil, List(Error(PostgresError))) {
  verify_queries(connection, [queries()])
}
