import dream_errors.{type Error}
import dream_postgres.{type Connection, type PostgresError, verify}
import snippets/user_checks.{queries}

/// Checks each query of the app against the database, at boot.
pub fn check_database(
  connection: Connection,
) -> Result(Nil, List(Error(PostgresError))) {
  verify(connection, [queries()])
}
