//// A prepare of one statement before and after a schema change, on a
//// connection of its own, for the tests of the prepare's answer.

import dream_postgres/driver/connection.{prepare, run, statement, stop}
import dream_postgres/internal/cell.{type StatementDescription}
import driver/server_connection.{run_control_script, start_connection}
import gleam/result.{map_error, replace, try}
import gleam/string.{inspect}

/// The table of the tests: a temporary table of three integer columns, so
/// each connection has its own.
const create_table_sql =
  "CREATE TEMPORARY TABLE prepared_after_change (a int, b int, c int)"

/// The statement that each test prepares and runs.
pub const select_all_sql = "SELECT * FROM prepared_after_change"

/// Makes the table on a connection to `port`, prepares `select_all_sql`,
/// runs `change_sql`, and prepares the same SQL again. Gives the two
/// descriptions, first and second.
pub fn prepare_around_change(
  port: Int,
  change_sql: String,
) -> Result(#(StatementDescription, StatementDescription), String) {
  use connection <- try(start_connection(port))
  let descriptions = {
    use Nil <- try(run_control_script(connection, create_table_sql))
    use first <- try(prepare_select_all(connection))
    use Nil <- try(run_control_script(connection, change_sql))
    use second <- try(prepare_select_all(connection))
    Ok(#(first, second))
  }
  stop(connection)
  descriptions
}

/// Makes the table on a connection to `port`, prepares `select_all_sql`,
/// runs `change_sql`, prepares the same SQL again, and then runs it.
/// Gives `Ok(Nil)` when the run worked.
pub fn run_after_changed_prepare(
  port: Int,
  change_sql: String,
) -> Result(Nil, String) {
  use connection <- try(start_connection(port))
  let ran = {
    use Nil <- try(run_control_script(connection, create_table_sql))
    use _first <- try(prepare_select_all(connection))
    use Nil <- try(run_control_script(connection, change_sql))
    use _second <- try(prepare_select_all(connection))
    run(connection, statement(select_all_sql), [], [], 5000)
    |> replace(Nil)
    |> map_error(inspect)
  }
  stop(connection)
  ran
}

fn prepare_select_all(
  connection: connection.Connection,
) -> Result(StatementDescription, String) {
  prepare(connection, statement(select_all_sql), 5000)
  |> map_error(inspect)
}
