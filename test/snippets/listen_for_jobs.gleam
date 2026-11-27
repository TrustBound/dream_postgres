import dream_errors.{type Error}
import dream_postgres.{
  type Config, type ListenMessage, type Listener, type PostgresError,
  type Subscription, listen, start_listener,
}
import gleam/erlang/process.{type Subject}
import gleam/result

/// Starts a listener and subscribes the subject to the channel `jobs`.
pub fn listen_for_jobs(
  config: Config,
  jobs: Subject(ListenMessage),
) -> Result(#(Listener, Subscription), Error(PostgresError)) {
  use listener <- result.try(start_listener(config))
  use subscription <- result.try(listen(listener, "jobs", jobs))
  Ok(#(listener, subscription))
}
