//// A matcher that holds one connection of the client pool of the chosen
//// version, with the tables of the docs' examples in a new schema of its
//// own, for some work.

import dream_postgres.{
  type Connection, one, query, script, single, with_connection,
}
import dream_postgres/codec
import dream_postgres/error
import dream_test/types.{
  type MatchResult, AssertionFailure, CustomMatcherFailure, MatchFailed, MatchOk,
}
import fixtures/server_pools.{type ServerPools}
import gleam/int
import gleam/option.{Some}
import gleam/result
import snippets/create_tables

/// Hold one connection of the pool of the chosen version, make a new
/// schema for it, named after its server process, put the schema first in
/// its search path, make the tables of `snippets/create_tables` there, run
/// `work` on the held connection, and drop the schema. Each test gets its
/// own tables, so tests that run at the same time do not share rows. The
/// chain goes on with what `work` gave, or fails when the schema cannot be
/// made or dropped.
///
/// ## Example
///
/// ```gleam
/// pools
/// |> should
/// |> run_with_example_tables(count_users)
/// |> be_ok()
/// |> be_equal(0)
/// |> or_fail_with("Expected no users")
/// ```
pub fn run_with_example_tables(
  result: MatchResult(ServerPools),
  work: fn(Connection) -> a,
) -> MatchResult(a) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(pools) -> run_on_chosen(pools, work)
  }
}

fn run_on_chosen(
  pools: ServerPools,
  work: fn(Connection) -> a,
) -> MatchResult(a) {
  let ran = {
    use pool <- result.try(server_pools.chosen(pools))
    with_connection(pool.connection, run_in_schema(_, work))
    |> result.map_error(error.describe)
    |> result.flatten
  }
  case ran {
    Ok(outcome) -> MatchOk(outcome)
    Error(reason) ->
      MatchFailed(AssertionFailure(
        operator: "run_with_example_tables",
        message: "",
        payload: Some(CustomMatcherFailure(
          actual: reason,
          description: "expected the tables of the examples to be made",
        )),
      ))
  }
}

fn run_in_schema(
  held: Connection,
  work: fn(Connection) -> a,
) -> Result(a, String) {
  use process_id <- result.try(
    query("SELECT pg_backend_pid()")
    |> one(single(codec.int), held)
    |> result.map_error(error.describe),
  )
  let schema = "examples_" <> int.to_string(process_id)
  use Nil <- result.try(
    script(
      "CREATE SCHEMA "
        <> schema
        <> "; SET search_path TO "
        <> schema
        <> ", public",
      held,
    )
    |> result.map_error(error.describe),
  )
  let made =
    create_tables.create_tables(held) |> result.map_error(error.describe)
  let outcome = result.map(made, fn(_made) { work(held) })
  let dropped =
    script("DROP SCHEMA " <> schema <> " CASCADE; RESET search_path", held)
    |> result.map_error(error.describe)
  use Nil <- result.try(dropped)
  outcome
}
