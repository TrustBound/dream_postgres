//// A matcher that runs work on a pool that a supervisor starts under a
//// name, and stops the supervisor after it.

import dream_postgres/config.{type Config}
import dream_postgres/pool.{type PoolName}
import dream_test/types.{
  type MatchResult, AssertionFailure, CustomMatcherFailure, MatchFailed, MatchOk,
}
import fixtures/supervisors
import gleam/erlang/process.{type Pid}
import gleam/option.{Some}
import gleam/otp/static_supervisor
import gleam/result
import gleam/string

/// Start a supervisor with the supervised pool of the config under the
/// name, run the work with the supervisor's pid, then stop the
/// supervisor. The chain goes on with the result of the work.
///
/// ## Example
///
/// ```gleam
/// server_pools.config(5441)
/// |> should
/// |> run_on_supervised_pool(name, fn(_supervisor) {
///   all(query("SELECT 1"), single(codec.int), named_connection(name))
/// })
/// |> be_ok()
/// |> be_equal([1])
/// |> or_fail_with("Expected the named pool to answer")
/// ```
pub fn run_on_supervised_pool(
  result: MatchResult(Config),
  name: PoolName,
  work: fn(Pid) -> a,
) -> MatchResult(a) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(config) ->
      start_supervisor(config, name)
      |> result.map(run_and_stop(_, work))
      |> matched
  }
}

fn start_supervisor(config: Config, name: PoolName) -> Result(Pid, String) {
  use child <- result.try(
    pool.supervised(config, name:)
    |> result.map_error(string.inspect),
  )
  static_supervisor.new(static_supervisor.OneForOne)
  |> static_supervisor.add(child)
  |> static_supervisor.start
  |> result.map(fn(started) { started.pid })
  |> result.map_error(string.inspect)
}

fn run_and_stop(supervisor: Pid, work: fn(Pid) -> a) -> a {
  let outcome = work(supervisor)
  supervisors.stop_supervisor(supervisor)
  outcome
}

fn matched(started: Result(a, String)) -> MatchResult(a) {
  case started {
    Ok(value) -> MatchOk(value)
    Error(reason) ->
      MatchFailed(AssertionFailure(
        operator: "run_on_supervised_pool",
        message: "the supervisor did not start: " <> reason,
        payload: Some(CustomMatcherFailure(
          actual: reason,
          description: "a supervisor with the pool",
        )),
      ))
  }
}
