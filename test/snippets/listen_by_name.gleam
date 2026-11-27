import dream_errors.{type Error}
import dream_postgres.{
  type ListenMessage, type ListenerName, type PostgresError, type Subscription,
  listen, named_listener,
}
import gleam/erlang/process.{type Subject}

/// Subscribes the subject to `jobs` on the listener that runs under the
/// name, as a supervisor starts it.
pub fn listen_by_name(
  notifications: ListenerName,
  jobs: Subject(ListenMessage),
) -> Result(Subscription, Error(PostgresError)) {
  listen(named_listener(notifications), "jobs", jobs)
}
