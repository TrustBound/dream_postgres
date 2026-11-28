import dream_errors.{type Error}
import dream_postgres/error.{type PostgresError}
import dream_postgres/listener.{
  type Listener, type Subscription, stop_listener, unlisten,
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
