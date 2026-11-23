//// The PostgreSQL server for the tests that need a real database.
////
//// Every test reads the server's URL from `url()`. Locally, `make db-up`
//// starts the server of `docker-compose.yml`, and the default URL points at
//// it. CI starts the same server as a service container. To use another
//// server, set `DREAM_POSTGRES_TEST_URL`.
////
//// Tests that write make their own schema with `with_schema`, so tests that
//// run at the same time never see each other's tables or rows.

import dream_postgres/client as postgres
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import pog

/// The environment variable that holds the URL of the test server.
pub const url_variable = "DREAM_POSTGRES_TEST_URL"

/// The URL of the server that `make db-up` starts.
pub const default_url = "postgresql://dream:dream@localhost:5436/dream_test"

@external(erlang, "database_ffi", "get_env")
fn get_env(name: String) -> Result(String, Nil)

@external(erlang, "database_ffi", "run_in_own_process")
fn run_in_own_process(run: fn() -> a) -> a

@external(erlang, "database_ffi", "unique_integer")
fn unique_integer() -> Int

@external(erlang, "database_ffi", "read_file")
fn read_file(path: String) -> Result(String, Nil)

/// Returns the URL of the test server: the value of `DREAM_POSTGRES_TEST_URL`,
/// or `default_url` when the variable is not set.
pub fn url() -> String {
  get_env(url_variable)
  |> result.unwrap(default_url)
}

/// Returns the config that `url()` gives, with its own pool name.
pub fn config() -> postgres.Config {
  let assert Ok(config) =
    postgres.parse_config(process.new_name("test_database"), url())
  config
}

/// Returns a URL for the host and port of the test server, with another
/// user, password and database name.
pub fn url_for(
  user user: String,
  password password: String,
  database database: String,
) -> String {
  let config = config()
  "postgresql://"
  <> user
  <> ":"
  <> password
  <> "@"
  <> config.host
  <> ":"
  <> int.to_string(config.port)
  <> "/"
  <> database
}

/// Calls `run` in a new process, and stops every pool that `run` started
/// when it returns.
///
/// A pool stays open after the test that started it, so without this the
/// pools of all tests add up past the server's `max_connections`.
pub fn with_own_pools(run: fn() -> a) -> a {
  run_in_own_process(run)
}

/// Gives `run` a pool of 2 connections whose `search_path` is a new, empty
/// schema, and drops the schema with all its tables after `run` returns.
///
/// An unqualified table name such as `users` is then a table of that
/// schema only, so each test has its own `users` table.
pub fn with_schema(run: fn(pog.Connection) -> a) -> a {
  use <- with_own_pools()
  let schema = "test_" <> int.to_string(unique_integer())
  let assert Ok(admin) =
    config()
    |> postgres.pool_size(1)
    |> postgres.connect()
  let assert Ok(_created) = execute(admin, "CREATE SCHEMA " <> schema)
  let assert Ok(db) =
    config()
    |> postgres.pool_size(2)
    |> pog.connection_parameter(name: "search_path", value: schema)
    |> postgres.connect()
  let value = run(db)
  let assert Ok(_dropped) =
    execute(admin, "DROP SCHEMA " <> schema <> " CASCADE")
  value
}

/// Runs each SQL statement in the first `sql` code block of the guide, in
/// order. Use it to make the tables that a guide tells the reader to make.
pub fn run_guide_sql(db: pog.Connection, guide_path: String) -> Nil {
  guide_sql_statements(guide_path)
  |> list.each(fn(statement) {
    let assert Ok(_returned) = execute(db, statement)
    Nil
  })
}

/// Returns the SQL statements of the first `sql` code block of the guide.
pub fn guide_sql_statements(guide_path: String) -> List(String) {
  let assert Ok(text) = read_file(guide_path)
  let assert Ok(#(_before, block_and_rest)) =
    string.split_once(text, "```sql\n")
  let assert Ok(#(block, _after)) = string.split_once(block_and_rest, "```")
  string.split(block, ";")
  |> list.map(string.trim)
  |> list.filter(fn(statement) { statement != "" })
}

/// Runs one SQL statement that returns no rows that the test needs.
pub fn execute(
  db: pog.Connection,
  sql: String,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  pog.query(sql)
  |> pog.execute(db)
}

/// Runs a query that returns one text column, and returns its values.
pub fn texts(
  db: pog.Connection,
  sql: String,
) -> Result(List(String), pog.QueryError) {
  pog.query(sql)
  |> pog.returning(decode.at([0], decode.string))
  |> pog.execute(db)
  |> result.map(fn(returned) { returned.rows })
}

/// Checks that the test server answers `SELECT 1`. Returns a message for
/// the developer when it does not.
pub fn check_reachable() -> Result(Nil, String) {
  use <- with_own_pools()
  use config <- result.try(
    postgres.parse_config(process.new_name("test_database"), url())
    |> result.map_error(fn(error) {
      url_variable <> " is not a valid URL: " <> string.inspect(error)
    }),
  )
  let assert Ok(db) =
    config
    |> postgres.pool_size(1)
    |> postgres.connect()
  execute(db, "SELECT 1")
  |> result.replace(Nil)
  |> result.map_error(fn(error) { not_reachable_message(config, error) })
}

fn not_reachable_message(
  config: postgres.Config,
  error: pog.QueryError,
) -> String {
  "The tests need a PostgreSQL server, and none answered at "
  <> config.host
  <> ":"
  <> int.to_string(config.port)
  <> " (database "
  <> config.database
  <> ", user "
  <> config.user
  <> "): "
  <> string.inspect(error)
  <> ".\nStart the test server with `make db-up`, or set "
  <> url_variable
  <> " to the URL of another server."
}
