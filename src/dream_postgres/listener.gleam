//// A listener for `LISTEN` and `NOTIFY`: one connection of its own that
//// sends the notifications of its channels to the subjects that subscribed.

import dream_errors.{type Error}
import dream_postgres/config.{type Config, pool_config}
import dream_postgres/driver/listener as driver_listener
import dream_postgres/driver/listener/process_message
import dream_postgres/driver/sink
import dream_postgres/error.{type PostgresError}
import dream_postgres/error/failure.{failure_with_no_query}
import dream_postgres/pool/connection_state.{
  settings_host, settings_port, settings_query_timeout_milliseconds,
}
import dream_postgres/query/driver_executor
import gleam/erlang/process.{type Monitor, type Subject}
import gleam/option.{None}
import gleam/otp/supervision.{type ChildSpecification}
import gleam/result

/// A listener: one connection of its own, outside the pool, that listens
/// for `NOTIFY` on the channels of its subscriptions. The first
/// subscription of a channel sends `LISTEN`, and when the last one ends,
/// the listener sends `UNLISTEN`. After a loss, the listener connects
/// again and listens again on each channel.
///
/// A listener is two processes: a registry that keeps the subscriptions,
/// and a session that owns the connection. A crash of the session of a
/// supervised listener keeps the subscriptions: each subject gets
/// `NotListening`, then `Listening` when the new session listens. A crash
/// of the registry ends every subscription. See `monitor_listener`.
pub opaque type Listener {
  Listener(listener: driver_listener.Listener)
}

/// One subscription of a subject to a channel. `unlisten` ends it.
pub opaque type Subscription {
  Subscription(subscription: process_message.Subscription)
}

/// The name of a listener that runs under a supervisor. Make it one time
/// when the program starts, with `process.new_name("notifications")`:
/// each name is an atom.
pub type ListenerName =
  process.Name(process_message.ListenerProcessMessage)

/// What the subject of a subscription gets.
pub type ListenMessage {
  /// A notification on the channel, from the server process with
  /// `process_id`.
  NotificationArrived(channel: String, payload: String, process_id: Int)
  /// The session does not listen on the channel: the connection is not up
  /// yet, or it is lost. `Listening` or `ListenFailed` follows when the
  /// connection is up again. A notification between the two can be lost.
  NotListening
  /// The listener listens on the channel again, after `NotListening`.
  Listening(channel: String)
  /// The `LISTEN` for the channel failed after a reconnect. The listener
  /// tries again after the next reconnect.
  ListenFailed(channel: String, error: Error(PostgresError))
}

/// Starts a listener with the server, the login and the TLS of the
/// config, linked to the calling process. It waits until its connection
/// is up: a server that does not answer gives an error. Each `LISTEN` may
/// take the query timeout of the config. The pool settings of the config
/// do not apply.
///
/// ### Start a listener and listen on a channel <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/listen_for_jobs.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_errors.{type Error}
/// import dream_postgres/config.{type Config}
/// import dream_postgres/error.{type PostgresError}
/// import dream_postgres/listener.{
///   type ListenMessage, type Listener, type Subscription, listen, start_listener,
/// }
/// import gleam/erlang/process.{type Subject}
/// import gleam/result
///
/// /// Starts a listener and subscribes the subject to the channel `jobs`.
/// pub fn listen_for_jobs(
///   config: Config,
///   jobs: Subject(ListenMessage),
/// ) -> Result(#(Listener, Subscription), Error(PostgresError)) {
///   use listener <- result.try(start_listener(config))
///   use subscription <- result.try(listen(listener, "jobs", jobs))
///   Ok(#(listener, subscription))
/// }
/// ```
pub fn start_listener(
  config: Config,
) -> Result(Listener, Error(PostgresError)) {
  use checked <- result.try(pool_config(config, [], None))
  driver_listener.start(process_message.ListenerConfig(
    connection: checked.connection,
    deadline_milliseconds: settings_query_timeout_milliseconds(
      checked.attachment,
    ),
  ))
  |> result.map(Listener)
  |> result.map_error(fn(start_error) {
    failure_with_no_query(driver_executor.listener_start_error_reason(
      start_error,
      settings_host(checked.attachment),
      settings_port(checked.attachment),
    ))
  })
}

/// The child specification of a listener under the app's supervisor,
/// under the name. The start does not wait for the server: until the
/// connection is up, each subject gets `NotListening`. After a restart
/// the new listener takes the same name, so a `named_listener` of it
/// keeps working. The config is checked here, so a wrong config is an
/// error before the supervisor starts. `stop_listener` stops it for good.
///
/// ### Start a listener under a supervisor <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/start_listener_supervisor.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/config.{type Config}
/// import dream_postgres/error.{describe}
/// import dream_postgres/listener.{type ListenerName, supervised_listener}
/// import gleam/otp/actor
/// import gleam/otp/static_supervisor.{type Supervisor}
/// import gleam/result
///
/// /// Starts the app's supervisor with a listener under the name
/// /// `notifications`.
/// pub fn start_listener_supervisor(
///   config: Config,
///   notifications: ListenerName,
/// ) -> Result(actor.Started(Supervisor), String) {
///   use listener_child <- result.try(
///     supervised_listener(config, name: notifications)
///     |> result.map_error(describe),
///   )
///   static_supervisor.new(static_supervisor.OneForOne)
///   |> static_supervisor.add(listener_child)
///   |> static_supervisor.start
///   |> result.replace_error("the supervisor did not start")
/// }
/// ```
pub fn supervised_listener(
  config: Config,
  name name: ListenerName,
) -> Result(ChildSpecification(Listener), Error(PostgresError)) {
  use checked <- result.try(pool_config(config, [], None))
  driver_listener.supervised(
    process_message.ListenerConfig(
      connection: checked.connection,
      deadline_milliseconds: settings_query_timeout_milliseconds(
        checked.attachment,
      ),
    ),
    name,
  )
  |> supervision.map_data(Listener)
  |> Ok
}

/// The listener that runs under the name. It holds only the name, so it
/// stays valid when the supervisor restarts the listener. While no
/// listener runs under the name, `listen` and `unlisten` fail with
/// `ListenerStopped`.
///
/// ### Listen through the name of a listener <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/listen_by_name.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_errors.{type Error}
/// import dream_postgres/error.{type PostgresError}
/// import dream_postgres/listener.{
///   type ListenMessage, type ListenerName, type Subscription, listen,
///   named_listener,
/// }
/// import gleam/erlang/process.{type Subject}
///
/// /// Subscribes the subject to `jobs` on the listener that runs under the
/// /// name, as a supervisor starts it.
/// pub fn listen_by_name(
///   notifications: ListenerName,
///   jobs: Subject(ListenMessage),
/// ) -> Result(Subscription, Error(PostgresError)) {
///   listen(named_listener(notifications), "jobs", jobs)
/// }
/// ```
pub fn named_listener(name: ListenerName) -> Listener {
  Listener(driver_listener.from_name(name))
}

/// A monitor of the listener's registry, owned by the calling process.
/// The registry keeps the subscriptions, so when it ends, by a crash or
/// by `stop_listener`, every subscription ends, and the caller gets the
/// `Down` of the monitor. A supervised listener comes back with no
/// subscription: after the `Down`, the app subscribes again through
/// `named_listener`, and monitors again. A crash of the session alone
/// gives no `Down`: the subscriptions stay. No listener that runs is
/// `ListenerStopped`.
///
/// ### Watch for the end of the registry <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/job_events.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_errors.{type Error}
/// import dream_postgres/error.{type PostgresError}
/// import dream_postgres/listener.{
///   type ListenMessage, type ListenerName, monitor_listener, named_listener,
/// }
/// import gleam/erlang/process.{type Down, type Selector, type Subject}
/// import gleam/result
///
/// pub type JobEvent {
///   JobMessage(message: ListenMessage)
///   /// The registry of the listener ended, and every subscription with it.
///   ListenerEnded(down: Down)
/// }
///
/// /// A selector of the messages of `jobs` and of the end of the listener's
/// /// registry.
/// pub fn job_events(
///   notifications: ListenerName,
///   jobs: Subject(ListenMessage),
/// ) -> Result(Selector(JobEvent), Error(PostgresError)) {
///   use monitor <- result.try(monitor_listener(named_listener(notifications)))
///   process.new_selector()
///   |> process.select_map(jobs, JobMessage)
///   |> process.select_specific_monitor(monitor, ListenerEnded)
///   |> Ok
/// }
/// ```
pub fn monitor_listener(
  listener: Listener,
) -> Result(Monitor, Error(PostgresError)) {
  driver_listener.monitor_registry(listener.listener)
  |> result.map_error(fn(listener_error) {
    failure_with_no_query(driver_executor.listener_error_reason(listener_error))
  })
}

/// Stops the listener and its connection. Its subscribers get no message.
///
/// ### End a subscription and stop the listener <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/stop_listening.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_errors.{type Error}
/// import dream_postgres/error.{type PostgresError}
/// import dream_postgres/listener.{
///   type Listener, type Subscription, stop_listener, unlisten,
/// }
/// import gleam/result
///
/// /// Ends the subscription, then stops the listener.
/// pub fn stop_listening(
///   listener: Listener,
///   subscription: Subscription,
/// ) -> Result(Nil, Error(PostgresError)) {
///   use Nil <- result.try(unlisten(listener, subscription))
///   stop_listener(listener)
///   Ok(Nil)
/// }
/// ```
pub fn stop_listener(listener: Listener) -> Nil {
  driver_listener.stop(listener.listener)
}

/// Subscribes the subject to the channel. The channel name is exact: `Jobs`
/// and `jobs` are two channels. The subscription ends with `unlisten`, or
/// when the process of the subject ends.
///
/// The result is `Ok` when the session listens on the channel, and also
/// when the connection is not up: then the subject gets `NotListening` at
/// once, and `Listening` when the session listens. A name of more than 63
/// bytes is `ChannelTooLong`, and a subject with no process is
/// `SubscriberHasNoProcess`.
///
/// ### Wait for the next notification <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/next_job.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/listener.{
///   type ListenMessage, ListenFailed, Listening, NotListening, NotificationArrived,
/// }
/// import gleam/erlang/process.{type Subject}
///
/// /// The payload of the next notification, or `Error(Nil)` when none came
/// /// within 5 seconds. It skips the messages about the listening state.
/// pub fn next_job(jobs: Subject(ListenMessage)) -> Result(String, Nil) {
///   case process.receive(jobs, 5000) {
///     Ok(NotificationArrived(payload:, ..)) -> Ok(payload)
///     Ok(NotListening) | Ok(Listening(..)) | Ok(ListenFailed(..)) ->
///       next_job(jobs)
///     Error(Nil) -> Error(Nil)
///   }
/// }
/// ```
pub fn listen(
  listener: Listener,
  channel: String,
  subject: Subject(ListenMessage),
) -> Result(Subscription, Error(PostgresError)) {
  driver_listener.subscribe(
    listener.listener,
    channel,
    sink.to(subject, listen_message),
  )
  |> result.map(Subscription)
  |> result.map_error(fn(listener_error) {
    failure_with_no_query(driver_executor.listener_error_reason(listener_error))
  })
}

/// Ends the subscription. When it was the last one of its channel, the
/// listener sends `UNLISTEN`.
///
/// ### End a subscription and stop the listener <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/stop_listening.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_errors.{type Error}
/// import dream_postgres/error.{type PostgresError}
/// import dream_postgres/listener.{
///   type Listener, type Subscription, stop_listener, unlisten,
/// }
/// import gleam/result
///
/// /// Ends the subscription, then stops the listener.
/// pub fn stop_listening(
///   listener: Listener,
///   subscription: Subscription,
/// ) -> Result(Nil, Error(PostgresError)) {
///   use Nil <- result.try(unlisten(listener, subscription))
///   stop_listener(listener)
///   Ok(Nil)
/// }
/// ```
pub fn unlisten(
  listener: Listener,
  subscription: Subscription,
) -> Result(Nil, Error(PostgresError)) {
  driver_listener.unsubscribe(listener.listener, subscription.subscription)
  |> result.map_error(fn(unsubscribe_error) {
    failure_with_no_query(driver_executor.unsubscribe_error_reason(
      unsubscribe_error,
    ))
  })
}

/// The listen message of the client for a message of the driver's
/// listener.
@internal
pub fn listen_message(
  message: process_message.ListenerMessage,
) -> ListenMessage {
  case message {
    process_message.NotificationArrived(notification:) ->
      NotificationArrived(
        channel: notification.channel,
        payload: notification.payload,
        process_id: notification.process_id,
      )
    process_message.NotListening -> NotListening
    process_message.Listening(channel:) -> Listening(channel:)
    process_message.ListenFailed(channel:, error: failure) ->
      ListenFailed(
        channel:,
        error: failure_with_no_query(driver_executor.listen_failure_reason(
          failure,
        )),
      )
  }
}
