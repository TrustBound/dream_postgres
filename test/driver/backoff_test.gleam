//// Proves the wait before a reconnect: the capped delay that a strategy
//// gets, the clamp of the strategy's wait, and the range of the default
//// strategy, full jitter.

import dream_postgres/driver/connection.{
  Backoff, BackoffStep, backoff_wait, full_jitter,
}
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import fixtures/backoff_strategies.{
  attempt_count, below_zero, capped_delay, far_too_long, previous_wait_and_one,
}
import gleam/list.{map, repeat}
import matchers/be_all_between.{be_all_between}

/// The tests of the backoff.
pub fn tests() -> TestSuite {
  describe("the wait before a reconnect", [
    step_tests(),
    clamp_tests(),
    full_jitter_tests(),
  ])
}

fn step_tests() {
  group("gives the strategy", [
    it("the first delay as the capped delay of the first wait", fn() {
      // Act
      let wait = backoff_wait(Backoff(100, 10_000, capped_delay), 0, 0)

      // Assert
      wait
      |> should
      |> be_equal(100)
      |> or_fail_with("Expected the first delay, 100")
    }),
    it("the first delay doubled for each failed attempt", fn() {
      // Act
      let wait = backoff_wait(Backoff(100, 10_000, capped_delay), 3, 0)

      // Assert
      wait
      |> should
      |> be_equal(800)
      |> or_fail_with("Expected 100 doubled three times, 800")
    }),
    it("a capped delay no longer than the longest delay", fn() {
      // Act
      let wait = backoff_wait(Backoff(100, 10_000, capped_delay), 10, 0)

      // Assert
      wait
      |> should
      |> be_equal(10_000)
      |> or_fail_with("Expected the longest delay, 10000")
    }),
    it("a capped delay that doubles at most 30 times", fn() {
      // Act
      let wait =
        backoff_wait(Backoff(1, 1_000_000_000_000, capped_delay), 100, 0)

      // Assert
      wait
      |> should
      |> be_equal(1_073_741_824)
      |> or_fail_with("Expected 1 doubled 30 times, 1073741824")
    }),
    it("the number of failed attempts", fn() {
      // Act
      let wait = backoff_wait(Backoff(100, 10_000, attempt_count), 7, 0)

      // Assert
      wait
      |> should
      |> be_equal(7)
      |> or_fail_with("Expected the attempt count, 7")
    }),
    it("the previous wait", fn() {
      // Act
      let wait =
        backoff_wait(Backoff(100, 10_000, previous_wait_and_one), 2, 250)

      // Assert
      wait
      |> should
      |> be_equal(251)
      |> or_fail_with("Expected the previous wait and one, 251")
    }),
  ])
}

fn clamp_tests() {
  group("keeps the strategy's wait", [
    it("at most the longest delay", fn() {
      // Act
      let wait = backoff_wait(Backoff(100, 10_000, far_too_long), 0, 0)

      // Assert
      wait
      |> should
      |> be_equal(10_000)
      |> or_fail_with("Expected the longest delay, 10000")
    }),
    it("at least 0", fn() {
      // Act
      let wait = backoff_wait(Backoff(100, 10_000, below_zero), 0, 0)

      // Assert
      wait
      |> should
      |> be_equal(0)
      |> or_fail_with("Expected 0 for a wait below zero")
    }),
  ])
}

fn full_jitter_tests() {
  group("full jitter", [
    it("waits from 0 to the capped delay over many draws", fn() {
      // Arrange
      let step =
        BackoffStep(
          attempt: 0,
          capped_delay_milliseconds: 100,
          previous_wait_milliseconds: 0,
        )

      // Act
      let draws = repeat(step, 10_000) |> map(full_jitter)

      // Assert
      draws
      |> should
      |> be_all_between(lowest: 0, highest: 100)
      |> or_fail_with("Expected each wait from 0 to 100")
    }),
  ])
}
