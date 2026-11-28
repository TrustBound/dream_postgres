//// A matcher that starts a recorder, attaches it to a config, runs some
//// work on the connection, and stops the connection with its recorder.

import dream_errors.{type Error}
import dream_postgres/config.{type Config}
import dream_postgres/error.{type PostgresError}
import dream_postgres/pool.{type Connection}
import dream_postgres/recorder.{type RecorderBuilder}
import dream_test/types.{
  type MatchResult, AssertionFailure, CustomMatcherFailure, MatchFailed, MatchOk,
}
import gleam/option.{Some}
import gleam/result
import gleam/string

/// Start the recorder of the builder, start the connection of `config`
/// with it, run `work` on the connection, and stop the connection. The
/// chain goes on with what `work` gave, or fails when the recorder or the
/// connection does not start.
///
/// ## Example
///
/// ```gleam
/// recorder.new(file: path)
/// |> recorder.mode(recorder.Passthrough)
/// |> should
/// |> run_with_recorder(server_pools.config(5441), recorded_scenarios.select_series)
/// |> be_ok()
/// |> be_equal("[1, 2, 3]")
/// |> or_fail_with("Expected the rows of the database")
/// ```
pub fn run_with_recorder(
  result: MatchResult(RecorderBuilder),
  config: Config,
  work: fn(Connection) -> a,
) -> MatchResult(a) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(builder) -> run_started(builder, config, work)
  }
}

fn run_started(
  builder: RecorderBuilder,
  config: Config,
  work: fn(Connection) -> a,
) -> MatchResult(a) {
  let ran = {
    use test_recorder <- result.try(recorder.start_recorder(builder))
    use connection <- result.try(
      config
      |> config.record(test_recorder)
      |> pool.start_pool,
    )
    let done = work(connection)
    pool.stop_pool(connection)
    Ok(done)
  }
  case ran {
    Ok(done) -> MatchOk(done)
    Error(failure) -> start_failure(failure)
  }
}

fn start_failure(failure: Error(PostgresError)) -> MatchResult(a) {
  MatchFailed(AssertionFailure(
    operator: "run_with_recorder",
    message: "",
    payload: Some(CustomMatcherFailure(
      actual: string.inspect(failure),
      description: "expected the recorder and its connection to start",
    )),
  ))
}
