//// A matcher that holds one connection of the client pool of the chosen
//// version, with a new temporary table, for some work.

import dream_postgres.{type Connection, script, with_connection}
import dream_postgres/error
import dream_test/types.{
  type MatchResult, AssertionFailure, CustomMatcherFailure, MatchFailed, MatchOk,
}
import fixtures/client_statements
import fixtures/server_pools.{type ServerPools}
import gleam/option.{Some}
import gleam/result

/// What the work on a table gave, and the ids that stayed in the table.
pub type TableRun(a) {
  TableRun(outcome: a, rows: List(Int))
}

/// Hold one connection of the pool of the chosen version, make the
/// temporary table `table (id int4)` on it, run `work` on the held
/// connection, read the ids of the table, and drop the table. The chain
/// goes on with what `work` gave and the ids, or fails when the table
/// cannot be made, read or dropped.
///
/// ## Example
///
/// ```gleam
/// pools
/// |> should
/// |> run_with_table("kept_rows", fn(held) {
///   client_statements.insert(held, "kept_rows", 1)
/// })
/// |> leave_rows([1])
/// |> be_ok()
/// |> be_equal(1)
/// |> or_fail_with("Expected one row inserted and kept")
/// ```
pub fn run_with_table(
  result: MatchResult(ServerPools),
  table: String,
  work: fn(Connection) -> a,
) -> MatchResult(TableRun(a)) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(pools) -> run_on_chosen(pools, table, work)
  }
}

fn run_on_chosen(
  pools: ServerPools,
  table: String,
  work: fn(Connection) -> a,
) -> MatchResult(TableRun(a)) {
  let ran = {
    use pool <- result.try(server_pools.chosen(pools))
    with_connection(pool.connection, fn(held) {
      run_on_table(held, table, work)
    })
    |> result.map_error(error.describe)
    |> result.flatten
  }
  case ran {
    Ok(table_run) -> MatchOk(table_run)
    Error(reason) ->
      MatchFailed(AssertionFailure(
        operator: "run_with_table",
        message: "",
        payload: Some(CustomMatcherFailure(
          actual: reason,
          description: "expected the table " <> table <> " to be made and read",
        )),
      ))
  }
}

fn run_on_table(
  held: Connection,
  table: String,
  work: fn(Connection) -> a,
) -> Result(TableRun(a), String) {
  use Nil <- result.try(
    script("CREATE TEMPORARY TABLE " <> table <> " (id int4)", held)
    |> result.map_error(error.describe),
  )
  let outcome = work(held)
  use rows <- result.try(
    client_statements.ids(held, table) |> result.map_error(error.describe),
  )
  use Nil <- result.try(
    script("DROP TABLE " <> table, held) |> result.map_error(error.describe),
  )
  Ok(TableRun(outcome:, rows:))
}
