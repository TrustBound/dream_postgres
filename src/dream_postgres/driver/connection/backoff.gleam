//// The backoff between two tries to connect again: its steps and the jittered
//// wait.

import gleam/int.{min}

/// How long the process waits before it connects again after a loss. The
/// capped delay is the first delay, twice that after each failed attempt,
/// up to the longest delay. The strategy turns each step into the wait,
/// which the driver keeps between 0 and the longest delay.
pub type Backoff {
  Backoff(
    first_delay_milliseconds: Int,
    longest_delay_milliseconds: Int,
    /// The wait for each step. `full_jitter` is the default.
    strategy: fn(BackoffStep) -> Int,
  )
}

/// What a backoff strategy gets for each wait.
pub type BackoffStep {
  BackoffStep(
    /// The number of failed attempts so far, 0 for the first wait.
    attempt: Int,
    /// The first delay, doubled for each failed attempt, up to the longest
    /// delay.
    capped_delay_milliseconds: Int,
    /// The wait before the previous attempt, 0 for the first wait.
    previous_wait_milliseconds: Int,
  )
}

/// The wait before a reconnect: the strategy's wait for the step, kept
/// between 0 and the longest delay.
///
/// ## Parameters
///
/// - `backoff`: the backoff settings
/// - `attempt`: the number of failed attempts so far, 0 for the first
/// - `previous_wait_milliseconds`: the wait before the previous attempt,
///   0 for the first
///
/// ## Returns
///
/// The wait in milliseconds.
pub fn backoff_wait(
  backoff: Backoff,
  attempt: Int,
  previous_wait_milliseconds: Int,
) -> Int {
  let doubled =
    int.bitwise_shift_left(backoff.first_delay_milliseconds, min(attempt, 30))
  let capped_delay_milliseconds =
    min(doubled, backoff.longest_delay_milliseconds)
  BackoffStep(attempt:, capped_delay_milliseconds:, previous_wait_milliseconds:)
  |> backoff.strategy
  |> int.clamp(min: 0, max: backoff.longest_delay_milliseconds)
}

/// The default strategy: a random wait between 0 and the capped delay,
/// both included. This is "Full Jitter" of the AWS Architecture Blog,
/// "Exponential Backoff And Jitter":
/// `sleep = random_between(0, min(cap, base * 2 ** attempt))`. It spreads
/// the reconnects of many connections after one outage.
///
/// ## Parameters
///
/// - `step`: the step of the wait
///
/// ## Returns
///
/// The wait in milliseconds.
pub fn full_jitter(step: BackoffStep) -> Int {
  int.random(step.capped_delay_milliseconds + 1)
}
