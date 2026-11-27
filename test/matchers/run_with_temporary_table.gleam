//// A matcher that holds one connection of the client pool of the chosen
//// version, with a new temporary table of any columns, for some work.

import dream_postgres.{type Connection, script, with_connection}
import dream_postgres/error
import dream_test/types.{
  type MatchResult, AssertionFailure, CustomMatcherFailure, MatchFailed, MatchOk,
}
import fixtures/server_pools.{type ServerPools}
import gleam/option.{Some}
import gleam/result

/// Hold one connection of the pool of the chosen version, make the
/// temporary table `table` with the column definitions `columns` on it,
/// run `work` on the held connection, and drop the table. `table` is SQL,
/// so a name with odd characters comes quoted. The chain goes on with
/// what `work` gave, or fails when the table cannot be made or dropped.
///
/// ## Example
///
/// ```gleam
/// pools
/// |> should
/// |> run_with_temporary_table("users", "(id int4, email text)", fn(held) {
///   query("SELECT count(*) FROM users") |> one(single(codec.int), held)
/// })
/// |> be_ok()
/// |> be_equal(0)
/// |> or_fail_with("Expected an empty table")
/// ```
pub fn run_with_temporary_table(
  result: MatchResult(ServerPools),
  table: String,
  columns: String,
  work: fn(Connection) -> a,
) -> MatchResult(a) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(pools) -> run_on_chosen(pools, table, columns, work)
  }
}

fn run_on_chosen(
  pools: ServerPools,
  table: String,
  columns: String,
  work: fn(Connection) -> a,
) -> MatchResult(a) {
  let ran = {
    use pool <- result.try(server_pools.chosen(pools))
    with_connection(pool.connection, fn(held) {
      run_on_table(held, table, columns, work)
    })
    |> result.map_error(error.describe)
    |> result.flatten
  }
  case ran {
    Ok(outcome) -> MatchOk(outcome)
    Error(reason) ->
      MatchFailed(AssertionFailure(
        operator: "run_with_temporary_table",
        message: "",
        payload: Some(CustomMatcherFailure(
          actual: reason,
          description: "expected the table " <> table <> " to be made",
        )),
      ))
  }
}

fn run_on_table(
  held: Connection,
  table: String,
  columns: String,
  work: fn(Connection) -> a,
) -> Result(a, String) {
  use Nil <- result.try(
    script("CREATE TEMPORARY TABLE " <> table <> " " <> columns, held)
    |> result.map_error(error.describe),
  )
  let outcome = work(held)
  use Nil <- result.try(
    script("DROP TABLE " <> table, held) |> result.map_error(error.describe),
  )
  Ok(outcome)
}
