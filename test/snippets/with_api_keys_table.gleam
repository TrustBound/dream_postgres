import dream_errors.{type Error}
import dream_postgres.{
  type Connection, type PostgresError, script, with_connection,
}
import gleam/result

/// Runs the work on one connection that has a temporary table `api_keys`,
/// so the test leaves no table on the server.
pub fn with_api_keys_table(
  connection: Connection,
  work: fn(Connection) -> Result(a, Error(PostgresError)),
) -> Result(a, Error(PostgresError)) {
  {
    use held <- with_connection(connection)
    use Nil <- result.try(script(
      "CREATE TEMPORARY TABLE api_keys (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner int4 NOT NULL,
  token text NOT NULL,
  password_hash text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
)",
      held,
    ))
    work(held)
  }
  |> result.flatten
}
