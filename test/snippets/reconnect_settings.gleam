import dream_postgres/config.{type Config, reconnect_delays, reconnect_strategy}
import dream_postgres/reconnect.{type ReconnectStep}

/// Waits 500 ms before the first reconnect, doubles the wait after each
/// failed attempt, and never waits longer than 30 seconds.
pub fn slow_reconnects(config: Config) -> Config {
  config
  |> reconnect_delays(
    first_delay_milliseconds: 500,
    longest_delay_milliseconds: 30_000,
  )
  |> reconnect_strategy(without_jitter)
}

/// Waits the whole capped delay of each step, with no random part.
pub fn without_jitter(step: ReconnectStep) -> Int {
  step.capped_delay_milliseconds
}
