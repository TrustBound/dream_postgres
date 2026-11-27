//// A matcher that starts a pool with the config of the chain, runs work on
//// it, and stops it.

import dream_postgres.{type Config, type Connection}
import dream_postgres/error
import dream_test/types.{
  type MatchResult, AssertionFailure, CustomMatcherFailure, MatchFailed, MatchOk,
}
import gleam/option.{Some}

/// Start a pool with the config, run `work` on it, and stop the pool. The
/// chain goes on with what `work` gives, or fails when the pool cannot
/// start.
///
/// ## Example
///
/// ```gleam
/// dream_postgres.default_config()
/// |> dream_postgres.port(5449)
/// |> should
/// |> run_on_started_pool(fn(connection) {
///   query("SELECT 1") |> all(single(codec.int), connection)
/// })
/// |> be_error()
/// |> have_kind_name()
/// |> be_equal("unavailable")
/// |> or_fail_with("Expected a pool with no server to be unavailable")
/// ```
pub fn run_on_started_pool(
  result: MatchResult(Config),
  work: fn(Connection) -> a,
) -> MatchResult(a) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(config) -> run_on_pool_of(config, work)
  }
}

fn run_on_pool_of(config: Config, work: fn(Connection) -> a) -> MatchResult(a) {
  case dream_postgres.start(config) {
    Ok(connection) -> {
      let outcome = work(connection)
      dream_postgres.stop(connection)
      MatchOk(outcome)
    }
    Error(failure) ->
      MatchFailed(AssertionFailure(
        operator: "run_on_started_pool",
        message: "",
        payload: Some(CustomMatcherFailure(
          actual: error.describe(failure),
          description: "expected the pool to start",
        )),
      ))
  }
}
