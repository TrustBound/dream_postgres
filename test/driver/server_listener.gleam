//// Test fixtures that start listeners on the driver servers, and the steps
//// that a listener test makes on its control connection: send a
//// notification, read the listener's last statement, and end the
//// listener's backend. Each listener has its own application name, so the
//// control connection finds its session in `pg_stat_activity`.
////
//// Each fixture that can fail gives a `Result` with a text error, so a
//// setup of dream_test reports the failure as a failed setup. The hooks
//// are for `dream_test/unit_context`: a describe gets its first context
//// from `listener_session_setup`, each test starts its own listener and
//// control connection in `before_each` and stops them in `after_each`.
//// The shared servers keep a session open until it ends, so every start
//// has a stop.

import dream_postgres/driver/connection.{
  type Backoff, type Connection, Backoff, ConnectionConfig,
}
import dream_postgres/driver/listener.{
  type Listener, type ListenerConfig, type ListenerMessage, type Subscription,
  ListenerConfig, start, stop, subscribe, unsubscribe,
}
import dream_test/context.{type Context}
import driver/listener_gate.{type Gate, start_gate, stop_gate}
import driver/server_connection.{
  application_config, backend_pid, query_text, setup_step, start_connection,
  stop_after_error,
}
import driver/servers.{type Server}
import gleam/erlang/process.{type Subject}
import gleam/int.{parse, to_string}
import gleam/result.{map_error, replace, try}
import gleam/string.{inspect, replace as replace_text}

// Listeners -------------------------------------------------------------------

/// The config of a listener to localhost on `port` as `dream`, with the
/// application name `application_name` and the reconnect `reconnect`.
pub fn listener_config(
  port: Int,
  application_name: String,
  reconnect: Backoff,
) -> Result(ListenerConfig, String) {
  use config <- try(application_config(port, application_name))
  Ok(ListenerConfig(
    connection: ConnectionConfig(..config, reconnect:),
    deadline_milliseconds: 5000,
  ))
}

/// Starts a listener to localhost on `port`, with a first reconnect delay
/// of `first_delay` milliseconds.
pub fn start_listener(
  port: Int,
  application_name: String,
  first_delay: Int,
) -> Result(Listener, String) {
  listener_config(port, application_name, Backoff(first_delay, 60_000))
  |> try(start_configured_listener)
}

/// Starts a listener with `config`.
pub fn start_configured_listener(
  config: ListenerConfig,
) -> Result(Listener, String) {
  start(config)
  |> map_error(fn(error) { "could not start a listener: " <> inspect(error) })
}

/// Subscribes `subscriber` to `channel`.
pub fn subscribe_to(
  listener: Listener,
  channel: String,
  subscriber: Subject(ListenerMessage),
) -> Result(Subscription, String) {
  subscribe(listener, channel, subscriber)
  |> map_error(fn(error) {
    "could not subscribe to " <> channel <> ": " <> inspect(error)
  })
}

/// Ends the subscription.
pub fn unsubscribe_from(
  listener: Listener,
  subscription: Subscription,
) -> Result(Nil, String) {
  unsubscribe(listener, subscription)
  |> map_error(fn(error) { "could not unsubscribe: " <> inspect(error) })
}

/// The next message of the subscriber, or an error after 5 seconds.
pub fn receive_message(
  subscriber: Subject(ListenerMessage),
) -> Result(ListenerMessage, String) {
  process.receive(subscriber, 5000)
  |> map_error(fn(_timeout) { "no listener message within 5 seconds" })
}

// A listener with a control connection ----------------------------------------

/// A listener and a control connection straight to the same server, the
/// backend process ID of the control connection, the listener's own
/// application name, two channels that no other test uses, and two
/// subscribers of the test process.
pub type ListenerSession {
  ListenerSession(
    listener: Listener,
    control: Connection,
    control_process_id: Int,
    application_name: String,
    channel: String,
    other_channel: String,
    first: Subject(ListenerMessage),
    second: Subject(ListenerMessage),
  )
}

/// Starts a listener to `server`, with a first reconnect delay of
/// `first_delay` milliseconds, and a control connection. The application
/// name and the channels get a number that no other test uses.
pub fn start_listener_session(
  server: Server,
  first_delay: Int,
) -> Result(ListenerSession, String) {
  let number = to_string(unique_number())
  let application_name = "svc827_listener_" <> number
  use listener <- try(start_listener(server.port, application_name, first_delay))
  start_connection(server.port)
  |> try(session_of(listener, _, application_name, number))
  |> map_error(stop_listener_after_error(listener, _))
}

fn session_of(
  listener: Listener,
  control: Connection,
  application_name: String,
  number: String,
) -> Result(ListenerSession, String) {
  use control_process_id <- try(
    backend_process_id(control) |> map_error(stop_after_error(control, _)),
  )
  Ok(ListenerSession(
    listener:,
    control:,
    control_process_id:,
    application_name:,
    channel: "svc827_channel_" <> number,
    other_channel: "svc827_other_" <> number,
    first: process.new_subject(),
    second: process.new_subject(),
  ))
}

fn stop_listener_after_error(listener: Listener, error: String) -> String {
  stop(listener)
  error
}

/// Stops the listener and the control connection. A teardown for
/// `after_each` and for the context setup. A listener that stopped already
/// stays stopped.
pub fn stop_listener_session(session: ListenerSession) -> Result(Nil, String) {
  Ok(stop_session(session))
}

fn stop_session(session: ListenerSession) -> Nil {
  stop(session.listener)
  connection.stop(session.control)
}

/// The number of `driver_connection_test_ffi`, which no other caller gets.
@external(erlang, "driver_connection_test_ffi", "unique_lock_key")
fn unique_number() -> Int

/// The context of a describe whose tests each get a listener session: one
/// session on `server` for the tree, which gives the context its first
/// value. `start_test_listener` gives each test its own.
///
/// ```gleam
/// describe("listener", listener_session_setup(first_driver_server), [
///   after_each(stop_listener_session),
///   before_each(start_test_listener(first_driver_server, 10)),
///   before_each(subscribe_first),
///   it("gives a notification", fn(session: ListenerSession) {
///     {
///       use _sent <- try(send_notification(session.control, session.channel, "hi"))
///       receive_message(session.first)
///     }
///     |> should
///     |> be_ok
///     |> or_fail_with("Expected the notification")
///   }),
/// ])
/// ```
pub fn listener_session_setup(server: Server) -> Context(ListenerSession) {
  context.setup(
    setup: fn() { start_listener_session(server, 10) },
    teardown: stop_listener_session,
  )
}

/// A `before_each` hook that starts a listener session on `server` for the
/// test. The session in the context it gets stays as it is.
pub fn start_test_listener(
  server: Server,
  first_delay: Int,
) -> fn(ListenerSession) -> Result(ListenerSession, String) {
  fn(_tree_session) { start_listener_session(server, first_delay) }
}

/// A hook that subscribes the first subscriber to the session's channel.
pub fn subscribe_first(
  session: ListenerSession,
) -> Result(ListenerSession, String) {
  subscribe_to(session.listener, session.channel, session.first)
  |> replace(session)
}

/// A hook that subscribes the first subscriber to `channel`.
pub fn subscribe_first_to(
  channel: String,
) -> fn(ListenerSession) -> Result(ListenerSession, String) {
  setup_step(fn(session: ListenerSession) {
    subscribe_to(session.listener, channel, session.first)
  })
}

/// A hook that subscribes the second subscriber to the session's channel.
pub fn subscribe_second(
  session: ListenerSession,
) -> Result(ListenerSession, String) {
  subscribe_to(session.listener, session.channel, session.second)
  |> replace(session)
}

/// A hook that subscribes the second subscriber to the session's other
/// channel.
pub fn subscribe_second_to_other(
  session: ListenerSession,
) -> Result(ListenerSession, String) {
  subscribe_to(session.listener, session.other_channel, session.second)
  |> replace(session)
}

/// A hook that subscribes the first subscriber to the session's channel
/// and ends that subscription again.
pub fn subscribe_and_unsubscribe_first(
  session: ListenerSession,
) -> Result(ListenerSession, String) {
  subscribe_to(session.listener, session.channel, session.first)
  |> try(unsubscribe_from(session.listener, _))
  |> replace(session)
}

/// A hook that ends the listener's backend from the control connection,
/// and waits until the server has no backend of the listener left.
pub fn end_session_backend(
  session: ListenerSession,
) -> Result(ListenerSession, String) {
  end_listener_backend(session.control, session.application_name)
  |> replace(session)
}

/// A hook that waits for the next message of the first subscriber.
pub fn wait_for_first_message(
  session: ListenerSession,
) -> Result(ListenerSession, String) {
  receive_message(session.first) |> replace(session)
}

/// What an act gave, with the listener session that it ran on.
pub type ListenerOutcome(outcome) {
  ListenerOutcome(session: ListenerSession, outcome: outcome)
}

/// The context of a describe whose tests each check one value of one
/// shared act: the setup starts a listener session on `server` and runs
/// `act` on it once, and the teardown stops the session. Use it when the
/// act waits in real time, so the wait happens once.
pub fn listener_act_setup(
  server: Server,
  first_delay: Int,
  act: fn(ListenerSession) -> Result(outcome, String),
) -> Context(ListenerOutcome(outcome)) {
  context.setup(
    setup: fn() {
      start_listener_session(server, first_delay) |> try(run_act(_, act))
    },
    teardown: fn(shared: ListenerOutcome(outcome)) {
      stop_listener_session(shared.session)
    },
  )
}

fn run_act(
  session: ListenerSession,
  act: fn(ListenerSession) -> Result(outcome, String),
) -> Result(ListenerOutcome(outcome), String) {
  act(session)
  |> result.map(ListenerOutcome(session, _))
  |> map_error(fn(error) {
    stop_session(session)
    error
  })
}

// A listener with one subscription --------------------------------------------

/// A listener with one subscription of `subscriber` on a channel that no
/// other test uses.
pub type SubscribedListener {
  SubscribedListener(
    listener: Listener,
    subscriber: Subject(ListenerMessage),
    subscription: Subscription,
  )
}

/// Starts a listener to `server` and subscribes a subscriber of the
/// calling process.
pub fn start_subscribed_listener(
  server: Server,
) -> Result(SubscribedListener, String) {
  let number = to_string(unique_number())
  let subscriber = process.new_subject()
  use listener <- try(start_listener(
    server.port,
    "svc827_subscribed_" <> number,
    10,
  ))
  subscribe_to(listener, "svc827_subscribed_" <> number, subscriber)
  |> result.map(SubscribedListener(listener, subscriber, _))
  |> map_error(stop_listener_after_error(listener, _))
}

/// Stops the listener. A teardown for `after_each` and for the context
/// setup.
pub fn stop_subscribed_listener(
  subscribed: SubscribedListener,
) -> Result(Nil, String) {
  Ok(stop(subscribed.listener))
}

/// The context of a describe whose tests each get a subscribed listener:
/// one for the tree, which gives the context its first value.
/// `start_test_subscribed` gives each test its own.
pub fn subscribed_setup(server: Server) -> Context(SubscribedListener) {
  context.setup(
    setup: fn() { start_subscribed_listener(server) },
    teardown: stop_subscribed_listener,
  )
}

/// A `before_each` hook that starts a subscribed listener on `server` for
/// the test.
pub fn start_test_subscribed(
  server: Server,
) -> fn(SubscribedListener) -> Result(SubscribedListener, String) {
  fn(_tree_subscribed) { start_subscribed_listener(server) }
}

/// A hook that ends the subscription.
pub fn end_subscription(
  subscribed: SubscribedListener,
) -> Result(SubscribedListener, String) {
  unsubscribe_from(subscribed.listener, subscribed.subscription)
  |> replace(subscribed)
}

// A listener behind a gate ----------------------------------------------------

/// A listener to a driver server through a gate proxy (see
/// `listener_gate`), with a first reconnect delay of 10 milliseconds, and
/// two subscribers of the calling process.
pub type GatedListener {
  GatedListener(
    listener: Listener,
    gate: Gate,
    first: Subject(ListenerMessage),
    second: Subject(ListenerMessage),
  )
}

/// What an act gave, with the gated listener that it ran on.
pub type GatedOutcome(outcome) {
  GatedOutcome(gated: GatedListener, outcome: outcome)
}

/// Starts a gate proxy to `server` and a listener through it.
pub fn start_gated_listener(server: Server) -> Result(GatedListener, String) {
  let #(port, gate) = start_gate(server.port)
  listener_config(port, "svc827_gate", Backoff(10, 50))
  |> try(start_configured_listener)
  |> result.map(GatedListener(
    _,
    gate,
    process.new_subject(),
    process.new_subject(),
  ))
  |> map_error(fn(error) {
    stop_gate(gate)
    error
  })
}

/// Stops the listener and the gate proxy.
pub fn stop_gated_listener(gated: GatedListener) -> Result(Nil, String) {
  Ok(stop_listener_and_gate(gated))
}

fn stop_listener_and_gate(gated: GatedListener) -> Nil {
  stop(gated.listener)
  stop_gate(gated.gate)
}

/// The context of a describe whose tests each check one value of one
/// shared act on a gated listener: the setup starts the gated listener on
/// `server` and runs `act` once, and the teardown stops it.
pub fn gated_act_setup(
  server: Server,
  act: fn(GatedListener) -> Result(outcome, String),
) -> Context(GatedOutcome(outcome)) {
  context.setup(
    setup: fn() { start_gated_listener(server) |> try(run_gated_act(_, act)) },
    teardown: fn(shared: GatedOutcome(outcome)) {
      stop_gated_listener(shared.gated)
    },
  )
}

fn run_gated_act(
  gated: GatedListener,
  act: fn(GatedListener) -> Result(outcome, String),
) -> Result(GatedOutcome(outcome), String) {
  act(gated)
  |> result.map(GatedOutcome(gated, _))
  |> map_error(fn(error) {
    stop_listener_and_gate(gated)
    error
  })
}

// The control connection ------------------------------------------------------

/// The backend process ID of the connection, as the number that a
/// notification carries.
pub fn backend_process_id(connection: Connection) -> Result(Int, String) {
  use text <- try(backend_pid(connection))
  parse(text)
  |> map_error(fn(_nil) { "expected a backend process ID, got " <> text })
}

/// Sends a notification on `channel` from the control connection.
pub fn send_notification(
  control: Connection,
  channel: String,
  payload: String,
) -> Result(Nil, String) {
  query_text(
    control,
    "SELECT pg_notify("
      <> literal(channel)
      <> ", "
      <> literal(payload)
      <> ")::text",
  )
  |> replace(Nil)
}

/// The last statement of the session with the application name
/// `application_name`.
pub fn listener_statement(
  control: Connection,
  application_name: String,
) -> Result(String, String) {
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
) -> Result(String, String) {
  wait_for_expected_statement(control, application_name, expected, 1000)
}

fn wait_for_expected_statement(
  control: Connection,
  application_name: String,
  expected: String,
  attempts: Int,
) -> Result(String, String) {
  let statement = listener_statement(control, application_name)
  case statement == Ok(expected), attempts {
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
/// until the server has no backend of the listener left.
pub fn end_listener_backend(
  control: Connection,
  application_name: String,
) -> Result(Nil, String) {
  use _ended <- try(query_text(
    control,
    "SELECT bool_and(pg_terminate_backend(pid))::text FROM pg_stat_activity"
      <> " WHERE application_name = "
      <> literal(application_name),
  ))
  wait_for_no_backend(control, application_name, 1000)
}

fn wait_for_no_backend(
  control: Connection,
  application_name: String,
  attempts: Int,
) -> Result(Nil, String) {
  let count =
    query_text(
      control,
      "SELECT count(*)::text FROM pg_stat_activity WHERE application_name = "
        <> literal(application_name),
    )
  case count, attempts {
    Ok("0"), _ -> Ok(Nil)
    Error(error), _ -> Error(error)
    _, 0 -> Error("the backend of the listener did not end")
    _, _ -> wait_for_no_backend(control, application_name, attempts - 1)
  }
}

fn literal(text: String) -> String {
  "'" <> replace_text(text, "'", "''") <> "'"
}
