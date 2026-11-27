import dream_errors.{type Error}
import dream_postgres.{
  type Listener, type PostgresError, type Subscription, stop_listener, unlisten,
}
import gleam/result

/// Ends the subscription, then stops the listener.
pub fn stop_listening(
  listener: Listener,
  subscription: Subscription,
) -> Result(Nil, Error(PostgresError)) {
  use Nil <- result.try(unlisten(listener, subscription))
  stop_listener(listener)
  Ok(Nil)
}
