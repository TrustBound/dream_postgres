//// Backoff strategies with no randomness, so a test knows each wait.

import dream_postgres/driver/connection/backoff.{type BackoffStep}

/// Waits exactly the capped delay: the first delay, doubled for each
/// failed attempt, up to the longest.
pub fn capped_delay(step: BackoffStep) -> Int {
  step.capped_delay_milliseconds
}

/// Waits one millisecond longer than the previous wait.
pub fn previous_wait_and_one(step: BackoffStep) -> Int {
  step.previous_wait_milliseconds + 1
}

/// Waits the number of failed attempts, in milliseconds.
pub fn attempt_count(step: BackoffStep) -> Int {
  step.attempt
}

/// Asks for a wait far longer than any longest delay of the tests.
pub fn far_too_long(_step: BackoffStep) -> Int {
  1_000_000_000
}

/// Asks for a wait below zero.
pub fn below_zero(_step: BackoffStep) -> Int {
  -5
}
