//// Test fixtures that start listeners on the driver servers, and the steps
//// that a listener test makes on its control connection: send a
//// notification, read the listener's last statement, and end the
//// listener's backend. Each listener has its own application name, so the
//// control connection finds its session in `pg_stat_activity`. A test
//// stops each listener and each connection that it starts.

import dream_postgres/driver/connection.{
  type Backoff, type Connection, Backoff, ConnectionConfig,
}
import dream_postgres/driver/listener.{
  type Listener, type ListenerConfig, type ListenerMessage, type Subscription,
  ListenerConfig, start, subscribe,
}
import driver/server_connection.{application_config, backend_pid, query_text}
import gleam/erlang/process.{type Subject}
import gleam/int.{parse}
import gleam/string.{inspect, replace}

// Listeners -------------------------------------------------------------------

/// The config of a listener to localhost on `port` as `dream`, with the
/// application name `application_name` and the reconnect `reconnect`.
pub fn listener_config(
  port: Int,
  application_name: String,
  reconnect: Backoff,
) -> ListenerConfig {
  ListenerConfig(
    connection: ConnectionConfig(
      ..application_config(port, application_name),
      reconnect:,
    ),
    deadline_milliseconds: 5000,
  )
}

/// Starts a listener to localhost on `port`, with a first reconnect delay
/// of `first_delay` milliseconds. It panics with the start error when the
/// listener does not start: that is a setup failure, not an assertion.
pub fn start_listener(
  port: Int,
  application_name: String,
  first_delay: Int,
) -> Listener {
  start_configured_listener(listener_config(
    port,
    application_name,
    Backoff(first_delay, 60_000),
  ))
}

/// Starts a listener with `config`. It panics with the start error when
/// the listener does not start.
pub fn start_configured_listener(config: ListenerConfig) -> Listener {
  case start(config) {
    Ok(listener) -> listener
    Error(error) -> panic as { "could not start a listener: " <> inspect(error) }
  }
}

/// Subscribes `subscriber` to `channel`. It panics with the error when the
/// subscribe fails: that is a setup failure.
pub fn subscribe_to(
  listener: Listener,
  channel: String,
  subscriber: Subject(ListenerMessage),
) -> Subscription {
  case subscribe(listener, channel, subscriber) {
    Ok(subscription) -> subscription
    Error(error) -> panic as { "could not subscribe: " <> inspect(error) }
  }
}

// The control connection ------------------------------------------------------

/// The backend process ID of the connection, as the number that a
/// notification carries.
pub fn backend_process_id(connection: Connection) -> Int {
  case parse(backend_pid(connection)) {
    Ok(process_id) -> process_id
    Error(Nil) -> panic as "expected a backend process ID"
  }
}

/// Sends a notification on `channel` from the control connection.
pub fn send_notification(
  control: Connection,
  channel: String,
  payload: String,
) -> Nil {
  let _sent =
    query_text(
      control,
      "SELECT pg_notify("
        <> literal(channel)
        <> ", "
        <> literal(payload)
        <> ")::text",
    )
  Nil
}

/// The last statement of the session with the application name
/// `application_name`.
pub fn listener_statement(
  control: Connection,
  application_name: String,
) -> String {
  query_text(
    control,
    "SELECT query FROM pg_stat_activity WHERE application_name = "
      <> literal(application_name),
  )
}

/// Asks the control connection again and again, without a sleep, until the
/// listener's last statement is `expected`, and gives the last statement.
pub fn wait_for_statement(
  control: Connection,
  application_name: String,
  expected: String,
) -> String {
  wait_for_expected_statement(control, application_name, expected, 1000)
}

fn wait_for_expected_statement(
  control: Connection,
  application_name: String,
  expected: String,
  attempts: Int,
) -> String {
  let statement = listener_statement(control, application_name)
  case statement == expected, attempts {
    True, _ -> statement
    False, 0 -> statement
    False, _ ->
      wait_for_expected_statement(
        control,
        application_name,
        expected,
        attempts - 1,
      )
  }
}

/// Ends the listener's backend from the control connection, and waits
/// until the server has no backend of the listener left. It panics when
/// the backend does not end: that is a setup failure.
pub fn end_listener_backend(
  control: Connection,
  application_name: String,
) -> Nil {
  let _ended =
    query_text(
      control,
      "SELECT bool_and(pg_terminate_backend(pid))::text FROM pg_stat_activity"
        <> " WHERE application_name = "
        <> literal(application_name),
    )
  wait_for_no_backend(control, application_name, 1000)
}

fn wait_for_no_backend(
  control: Connection,
  application_name: String,
  attempts: Int,
) -> Nil {
  let count =
    query_text(
      control,
      "SELECT count(*)::text FROM pg_stat_activity WHERE application_name = "
        <> literal(application_name),
    )
  case count, attempts {
    "0", _ -> Nil
    _, 0 -> panic as "the backend of the listener did not end"
    _, _ -> wait_for_no_backend(control, application_name, attempts - 1)
  }
}

fn literal(text: String) -> String {
  "'" <> replace(text, "'", "''") <> "'"
}
