//// The reconnect backoff of the config: the default strategy, and a
//// strategy the app gives.

import dream_postgres/config
import dream_postgres/reconnect.{ReconnectStep, full_jitter}
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, it}
import fixtures/free_ports
import fixtures/server_pools
import gleam/erlang/process
import matchers/receive_message.{receive_message}
import matchers/run_on_started_pool.{run_on_started_pool}

pub fn tests() -> TestSuite {
  describe("reconnect backoff", [
    it("full jitter waits no time when the capped delay is 0", fn() {
      // Act and assert
      ReconnectStep(
        attempt: 1,
        capped_delay_milliseconds: 0,
        previous_wait_milliseconds: 0,
      )
      |> full_jitter
      |> should
      |> be_equal(0)
      |> or_fail_with("Expected a wait of 0 for a capped delay of 0")
    }),
    it("calls the app's strategy for the first wait", fn() {
      // Arrange
      let steps = process.new_subject()

      // Act and assert
      server_pools.config(free_ports.free_port())
      |> config.pool_size(1)
      |> config.reconnect_delays(
        first_delay_milliseconds: 5,
        longest_delay_milliseconds: 40,
      )
      |> config.reconnect_strategy(fn(step) {
        process.send(steps, step)
        0
      })
      |> should
      |> run_on_started_pool(fn(_connection) { Nil })
      |> receive_message(steps, within: 2000)
      |> be_equal(ReconnectStep(
        attempt: 0,
        capped_delay_milliseconds: 5,
        previous_wait_milliseconds: 0,
      ))
      |> or_fail_with(
        "Expected the strategy to get the first wait with a delay of 5 ms",
      )
    }),
  ])
}
