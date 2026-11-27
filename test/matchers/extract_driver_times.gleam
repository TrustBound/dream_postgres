//// A matcher that gives the time settings that a client config gives the
//// driver pool.

import dream_postgres.{type Config}
import dream_postgres/error
import dream_test/types.{
  type MatchResult, AssertionFailure, CustomMatcherFailure, MatchFailed, MatchOk,
}
import gleam/option.{Some}

/// Give the time settings of the driver pool for the config, in
/// milliseconds: `#(connect timeout, setup timeout, cancel timeout,
/// health check interval, return rollback timeout)`. The chain fails when
/// the config gives no driver pool config.
///
/// ## Example
///
/// ```gleam
/// dream_postgres.default_config()
/// |> should
/// |> extract_driver_times()
/// |> be_equal(#(5000, 10_000, 2000, 30_000, 5000))
/// |> or_fail_with("Expected the default times")
/// ```
pub fn extract_driver_times(
  result: MatchResult(Config),
) -> MatchResult(#(Int, Int, Int, Int, Int)) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(config) -> driver_times_of(config)
  }
}

fn driver_times_of(config: Config) -> MatchResult(#(Int, Int, Int, Int, Int)) {
  case dream_postgres.driver_pool_config(config, Nil) {
    Ok(pool_config) ->
      MatchOk(#(
        pool_config.connection.transport.connect_timeout_milliseconds,
        pool_config.connection.setup_timeout_milliseconds,
        pool_config.connection.cancel_timeout_milliseconds,
        pool_config.health_check_interval_milliseconds,
        pool_config.rollback_deadline_milliseconds,
      ))
    Error(failure) ->
      MatchFailed(AssertionFailure(
        operator: "extract_driver_times",
        message: "",
        payload: Some(CustomMatcherFailure(
          actual: error.describe(failure),
          description: "expected a driver pool config",
        )),
      ))
  }
}
