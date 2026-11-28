//// A prepare of one statement before a schema change, and a
//// `describe_current` or a prepare after it, on a connection of its own.

import dream_postgres/driver/cell.{type StatementDescription}
import dream_postgres/driver/connection.{stop}
import dream_postgres/driver/connection/call as connection_call
import dream_postgres/driver/connection/extended_query.{
  describe_current, prepare, run,
}
import dream_postgres/driver/connection/outcome.{type Outcome}
import dream_postgres/driver/connection/request_failure.{
  type PrepareError, type RunError,
}
import dream_postgres/driver/connection/statement.{statement}
import driver/server_connection.{run_control_simple_query, start_connection}
import gleam/result.{map_error, replace, try}
import gleam/string.{inspect}

/// The table of the tests: a temporary table of three integer columns, so
/// each connection has its own.
const create_table_sql =
  "CREATE TEMPORARY TABLE prepared_after_change (a int, b int, c int)"

/// The statement that each test prepares and runs.
pub const select_all_sql = "SELECT * FROM prepared_after_change"

/// Makes the table on a connection to `port`, prepares `select_all_sql`,
/// runs `change_sql`, and gives the server's description of the same SQL
/// now, with `describe_current`. Gives the two descriptions, first and
/// second.
pub fn prepare_around_change(
  port: Int,
  change_sql: String,
) -> Result(#(StatementDescription, StatementDescription), String) {
  use connection <- try(start_connection(port))
  let descriptions = {
    use Nil <- try(run_control_simple_query(connection, create_table_sql))
    use first <- try(prepare_select_all(connection))
    use Nil <- try(run_control_simple_query(connection, change_sql))
    use second <- try(describe_select_all(connection))
    Ok(#(first, second))
  }
  stop(connection)
  descriptions
}

/// Makes the table on a connection to `port`, prepares `select_all_sql`,
/// runs `change_sql`, describes the same SQL with `describe_current`, and
/// then runs it. Gives `Ok(Nil)` when the run worked.
pub fn run_after_changed_prepare(
  port: Int,
  change_sql: String,
) -> Result(Nil, String) {
  use connection <- try(start_connection(port))
  let ran = {
    use Nil <- try(run_control_simple_query(connection, create_table_sql))
    use _first <- try(prepare_select_all(connection))
    use Nil <- try(run_control_simple_query(connection, change_sql))
    use _second <- try(describe_select_all(connection))
    run(connection, statement(select_all_sql), [], [], 5000)
    |> replace(Nil)
    |> map_error(inspect)
  }
  stop(connection)
  ran
}

fn prepare_select_all(
  connection: connection_call.Connection,
) -> Result(StatementDescription, String) {
  prepare(connection, statement(select_all_sql), 5000)
  |> map_error(inspect)
}

fn describe_select_all(
  connection: connection_call.Connection,
) -> Result(StatementDescription, String) {
  describe_current(connection, statement(select_all_sql), 5000)
  |> map_error(inspect)
}

/// What a prepare and a run of `select_all_sql` gave after a schema
/// change, when the cache held the statement from before it.
pub type StaleOutcome {
  StaleOutcome(prepared: StatementDescription, ran: Result(Outcome, RunError))
}

/// Makes the table on a connection to `port`, prepares `select_all_sql`,
/// runs `change_sql`, prepares the same SQL again, from the cache, and
/// runs it.
pub fn prepare_and_run_after_change(
  port: Int,
  change_sql: String,
) -> Result(StaleOutcome, String) {
  use connection <- try(start_connection(port))
  let outcome = {
    use Nil <- try(run_control_simple_query(connection, create_table_sql))
    use _first <- try(prepare_select_all(connection))
    use Nil <- try(run_control_simple_query(connection, change_sql))
    use prepared <- try(prepare_select_all(connection))
    let ran = run(connection, statement(select_all_sql), [], [], 5000)
    Ok(StaleOutcome(prepared:, ran:))
  }
  stop(connection)
  outcome
}

/// Starts a connection to `port`, stops it, and asks it for the server's
/// description of `select_all_sql`.
pub fn describe_on_stopped_connection(
  port: Int,
) -> Result(Result(StatementDescription, PrepareError), String) {
  use connection <- try(start_connection(port))
  stop(connection)
  Ok(describe_current(connection, statement(select_all_sql), 5000))
}
