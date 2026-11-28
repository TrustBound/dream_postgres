//// One wait before a connection tries to connect again, and the default
//// strategy that picks it.

import dream_postgres/driver/connection/backoff as connection_backoff

/// One wait before a connection tries to connect again.
pub type ReconnectStep {
  ReconnectStep(
    /// The number of failed attempts so far: 0 for the first wait.
    attempt: Int,
    /// The first delay, doubled for each failed attempt, up to the longest
    /// delay.
    capped_delay_milliseconds: Int,
    /// The wait before the previous attempt: 0 for the first wait.
    previous_wait_milliseconds: Int,
  )
}

/// The default reconnect strategy, "full jitter": a random wait from 0 to
/// the capped delay of the step. Connections that lost the server at the
/// same moment then come back at different moments.
pub fn full_jitter(step: ReconnectStep) -> Int {
  connection_backoff.full_jitter(connection_backoff.BackoffStep(
    attempt: step.attempt,
    capped_delay_milliseconds: step.capped_delay_milliseconds,
    previous_wait_milliseconds: step.previous_wait_milliseconds,
  ))
}
