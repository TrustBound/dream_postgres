//// A new schema with the users table of `test/fixtures/sql/queries_users.sql`,
//// for the recorded queries guide.

import dream_postgres/client as postgres
import fixtures/test_database
import gleam/int

@external(erlang, "database_ffi", "unique_integer")
fn unique_integer() -> Int

/// Gives `run` the URL of the test server with `search_path` set to a new
/// schema that has the users table, and drops the schema after `run`.
pub fn with_users_url(run: fn(String) -> a) -> a {
  use <- test_database.with_own_pools()
  let schema = "guide_" <> int.to_string(unique_integer())
  let assert Ok(admin) =
    test_database.config()
    |> postgres.pool_size(1)
    |> postgres.connect()
  let assert Ok(_created) =
    test_database.execute(admin, "CREATE SCHEMA " <> schema)
  let assert Ok(db) =
    test_database.config()
    |> postgres.pool_size(1)
    |> postgres.connect()
  let assert Ok(_path) =
    test_database.execute(db, "SET search_path TO " <> schema)
  test_database.run_sql_file(db, "test/fixtures/sql/queries_users.sql")
  let value = run(test_database.url() <> "?search_path=" <> schema)
  let assert Ok(_dropped) =
    test_database.execute(admin, "DROP SCHEMA " <> schema <> " CASCADE")
  value
}
