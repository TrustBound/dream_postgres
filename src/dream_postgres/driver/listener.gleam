//// A listener: it gives the notifications of `NOTIFY` to the processes
//// that subscribe to a channel, from a connection process of its own,
//// outside any pool.
////
//// A listener is two gleam_otp actors:
////
//// - The registry keeps the subscriptions: the channel, the subscriber's
////   sink, and a monitor on the process that owns the sink's subject. It
////   does no I/O.
////   Each call of this module goes to it. It decides when a channel needs
////   `LISTEN` or `UNLISTEN`, and asks the session to send it.
//// - The session owns the connection process. It sends each `LISTEN` and
////   `UNLISTEN` that the registry asks for, and passes each notification
////   and each change of the connection to the registry.
////
//// The first subscriber of a channel makes the registry ask for `LISTEN`,
//// and when the last one goes, by `unsubscribe` or because its process
//// stopped, the registry asks for `UNLISTEN`. Channel names are exact: the
//// session quotes them, so `Jobs` and `jobs` are two channels.
////
//// The connection process sends each notification to the session as it
//// arrives, the session passes it to the registry, and the registry sends
//// it on to each subscriber of its channel, in the order the server sent
//// them.
////
//// The registry sends each message to a subscriber through the
//// subscriber's sink, so the map of the sink runs in the registry's
//// process. When that map crashes, the registry drops the sink: it ends
//// the subscription, the same as when the subscriber's process stops, and
//// asks for `UNLISTEN` when it was the last one of its channel. The other
//// subscribers and the listener go on (see `driver/sink`).
////
//// A subscriber hears whether its session listens. When the connection is
//// lost, each subscriber gets `NotListening` at once, and the connection
//// process connects again. The new session listens on nothing, so the
//// registry asks for `LISTEN` again for each channel, and each subscriber
//// gets `Listening`, or `ListenFailed` when that `LISTEN` failed. The
//// server keeps no notification for a session that is gone, so the
//// notifications between `NotListening` and `Listening` may be missed.
////
//// The rule for a subscribe is exact. The session is up from the moment
//// the registry handles the session's report that its connection logged
//// in, until the registry handles a loss or the end of that session.
////
//// - A subscribe that the registry handles while the session is up sends
////   `LISTEN` (for the first subscriber of the channel) and returns once
////   the session listens. The subscriber gets no message for it.
//// - A subscribe that the registry handles while the session is not up
////   (not connected yet, lost, or no session) sends nothing. The
////   subscriber gets `NotListening` at once, then `Listening` or
////   `ListenFailed` after the next login.
//// - A `LISTEN` that meets a loss the registry has not handled yet gives
////   `NotListening` the same way.
////
//// So a subscriber gets `NotListening` first if and only if the session is
//// not up when the registry handles its subscribe. A test that needs one
//// exact sequence controls the connection: with the server out of reach,
//// for example behind a closed TCP gate, a subscribe always gets
//// `NotListening`, then `Listening` once the gate opens. With a listener
//// from `start`, which returns once its session is up, a subscribe always
//// gets no message.
////
//// A crash of the session is a loss too. Under a supervisor
//// (`supervised`), the registry and the session are the two children of a
//// small supervisor with the strategy rest_for_one. When the session
//// stops, each subscriber that listened gets `NotListening`, and the
//// supervisor starts a new session. The new session tells the registry
//// when its connection is up, the registry asks it for `LISTEN` on each
//// channel, and each subscriber gets `Listening` or `ListenFailed`, with
//// no new subscribe. A crash of the registry ends every subscription: the
//// supervisor starts the registry and the session again, with no
//// subscriber. A subscriber sees that crash with `monitor_registry`.
////
//// A listener from `start` has no supervisor: the registry is linked to
//// the caller, and the session to the registry. A crash of its session
//// stops the registry too.
////
//// A call to the listener has no timeout: the registry answers each one
//// after at most one `LISTEN` or `UNLISTEN` of its session, and a listener
//// that is gone gives `ListenerProcessDown`. So a subscription never exists
//// without the handle that ends it.
////
//// This module is internal to dream_postgres.

import dream_postgres/driver/cell.{type ServerReport, type TransactionStatus}
import dream_postgres/driver/connection
import dream_postgres/driver/connection/call.{type Connection}
import dream_postgres/driver/connection/event.{
  type ConnectError, type ConnectionEvent, Connected, Disconnected,
  ReconnectFailed, Reconnected,
} as connection_event
import dream_postgres/driver/connection/outcome.{type Notification}
import dream_postgres/driver/connection/request_failure.{
  type SimpleQueryError, ConnectionEnded, ConnectionProcessDown, DeadlinePassed,
  SimpleQueryCopyRefused, SimpleQueryFailed, SimpleQueryNotConnected,
  SimpleQueryRefused, SimpleQueryRequestFailed, SimpleQueryUnencodable,
}
import dream_postgres/driver/connection/settings.{
  type ConnectionConfig, ConnectionConfig,
}
import dream_postgres/driver/connection/simple_query as connection_simple_query
import dream_postgres/driver/sink.{
  type Delivery, type Sink, Delivered, MapFailed,
}
import gleam/bit_array.{byte_size}
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom
import gleam/erlang/process.{
  type Down, type Monitor, type Name, type Pid, type Subject, subject_owner,
}
import gleam/function.{identity}
import gleam/list.{any, filter, fold, unique}
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/static_supervisor.{AnySignificant, RestForOne}
import gleam/otp/supervision.{type ChildSpecification, Transient}
import gleam/result.{map_error, replace, replace_error, try}
import gleam/string.{replace as replace_text}

// Types -----------------------------------------------------------------------

/// Everything a listener needs.
pub type ListenerConfig {
  ListenerConfig(
    /// The connection of the listener. The session sets its `events` and
    /// its `notifications` to sinks of its own subjects, and its `notices`
    /// to `None`.
    connection: ConnectionConfig,
    /// The longest time that each `LISTEN` and `UNLISTEN` can take.
    deadline_milliseconds: Int,
  )
}

/// What a subscriber gets from the listener.
pub type ListenerMessage {
  /// A notification on the channel of the subscription.
  NotificationArrived(notification: Notification)
  /// The session does not listen on the channel of the subscription: the
  /// connection is not up yet, it is lost, or the session stopped.
  /// `Listening` or `ListenFailed` follows once the session sent `LISTEN`
  /// on a connection that is up.
  NotListening
  /// The session sent `LISTEN` for the channel on a connection that is
  /// up: the first one, or a new one after a loss or a new session.
  /// Notifications on the channel between the last `NotListening` and this
  /// message may be missed.
  Listening(channel: String)
  /// The `LISTEN` for the channel failed on a connection that is up, so
  /// the session does not listen on it. The registry asks again after the
  /// next reconnect. A `LISTEN` that meets a loss gives no message: the
  /// subscriber got `NotListening` already, and `Listening` follows the
  /// next reconnect.
  ListenFailed(channel: String, error: ListenFailure)
}

/// Why the `LISTEN` for a channel failed on a connection that is up.
pub type ListenFailure {
  /// The server refused the `LISTEN`. The session stays usable.
  ListenRefused(report: ServerReport, transaction_status: TransactionStatus)
  /// The server answered the `LISTEN` as no PostgreSQL server does: with
  /// an error after a first result, or with a COPY. The session stays
  /// usable.
  ListenAnswerUnexpected
  /// The `LISTEN` did not end by the deadline of the listener. `cancelled`
  /// says whether the server confirmed a cancel.
  ListenDeadlinePassed(cancelled: Bool)
  /// The channel name holds a zero byte, so the `LISTEN` cannot be
  /// written. No byte went to the server.
  ChannelHasZeroByte
  /// The connection process of the session is gone, for example because
  /// an exit signal stopped it.
  ListenerConnectionDown
}

/// Why a subscribe failed.
pub type ListenerError {
  /// The channel name has more than 63 bytes. PostgreSQL cuts such a name
  /// short, so its notifications would come with another name.
  ChannelTooLong(channel: String)
  /// The subject of the subscriber's sink has no process: it has a name
  /// that no process has.
  SubscriberHasNoProcess
  /// The `LISTEN` failed on a connection that is up, so the subscription
  /// is not kept. A connection that is not up is not a failure: the
  /// subscription is kept and gets `NotListening`.
  SubscribeFailed(error: ListenFailure)
  /// The registry of the listener is gone.
  ListenerProcessDown
}

/// Why an unsubscribe failed.
pub type UnsubscribeError {
  /// The registry of the listener is gone.
  ListenerGone
}

/// Why a listener did not start.
pub type StartError {
  /// Its connection could not connect and log in.
  ConnectFailed(error: ConnectError)
  /// The registry or the session did not start.
  ListenerNotStarted(error: actor.StartError)
}

/// A listener's registry, or the name it runs under. Each call finds the
/// process that has the subject now, so a handle of `from_name` stays
/// valid when a supervisor starts the listener again.
pub opaque type Listener {
  Listener(subject: Subject(ListenerProcessMessage))
}

/// One subscription to one channel. `unsubscribe` ends it.
pub opaque type Subscription {
  Subscription(monitor: Monitor)
}

/// A reply target: an alias of the caller (see the FFI module).
type ReplyTo(reply)

/// What the registry of a listener receives: the calls of this module, and
/// the reports of its session. A program names a supervised listener with
/// `process.new_name`, for this type.
pub opaque type ListenerProcessMessage {
  SubscribeRequest(
    channel: String,
    subscriber: Sink(ListenerMessage),
    owner: Pid,
    reply: ReplyTo(Result(Subscription, ListenerError)),
  )
  UnsubscribeRequest(subscription: Subscription, reply: ReplyTo(Nil))
  StopRequest(reply: ReplyTo(Nil))
  /// A session started. The registry monitors it, and asks it from now on.
  SessionStarted(session: Subject(SessionMessage), pid: Pid)
  /// The connection of the session connected, the first time or again.
  SessionUp
  /// The connection of the session lost its session.
  SessionLost
  /// An attempt of the connection to connect for the first time failed.
  SessionConnectFailed(error: ConnectError)
  /// A notification that the connection of the session got.
  NotificationReceived(notification: Notification)
  /// A process that the registry monitors stopped: a subscriber's or the
  /// session.
  MonitoredProcessDown(monitor: Monitor)
}

/// What the session of a listener receives: the requests of its registry,
/// and what its connection process sends.
type SessionMessage {
  ListenRequest(channel: String, reply: ReplyTo(Listened))
  UnlistenRequest(channel: String, reply: ReplyTo(Nil))
  /// Closes the connection, and stops the session.
  CloseRequest(reply: ReplyTo(Nil))
  ConnectionNotified(notification: Notification)
  ConnectionChanged(event: ConnectionEvent)
}

/// What the starter of `start` waits for.
type Opening {
  Opened(result: Result(Nil, ConnectError))
  ListenerDown(reason: process.ExitReason)
}

/// Where a registry runs.
type Placement {
  /// Started by `start`: the registry starts its session, linked to it,
  /// and answers the starter after the first attempt of the connection.
  Linked(starter: Subject(Result(Nil, ConnectError)))
  /// A child of the listener's supervisor, under the name: the supervisor
  /// starts the session.
  Named(name: Name(ListenerProcessMessage))
}

/// A subscriber of one channel. `listening` says whether the session
/// listens on the channel: it is `False` from a loss until the `LISTEN`
/// after the reconnect.
type Subscriber {
  Subscriber(
    channel: String,
    /// Where each message to the subscriber goes.
    sink: Sink(ListenerMessage),
    listening: Bool,
  )
}

/// What a `LISTEN` gave.
type Listened {
  /// The session listens on the channel.
  ListenWorked
  /// The connection is not up: it is lost, a supervised connection did not
  /// connect yet, or the session is gone. The registry asks again after the
  /// next reconnect or the next session.
  ListenLost
  /// The `LISTEN` failed on a connection that is up.
  ListenNotDone(failure: ListenFailure)
}

/// What a subscribe does.
type Admission {
  /// Adds the subscriber. With `listening` `False`, it gets `NotListening`.
  Admit(listening: Bool)
  /// Refuses the subscriber with the failure of its `LISTEN`.
  Refuse(failure: ListenFailure)
}

/// The session that the registry asks, and the registry's monitor of it.
type SessionLink {
  SessionLink(subject: Subject(SessionMessage), pid: Pid, monitor: Monitor)
}

type RegistryState {
  RegistryState(
    /// The session that runs now. A registry has none until its session
    /// started, and none from the end of a session until the next one
    /// started.
    session: Option(SessionLink),
    /// Whether the session is up: the registry handled the session's
    /// report that its connection logged in, and no loss or new session
    /// since. Only an up session gets a `LISTEN` for a subscribe.
    up: Bool,
    /// The starter of `start`, until the first attempt of the connection
    /// ended. A supervised listener has none.
    starter: Option(Subject(Result(Nil, ConnectError))),
    /// Each subscription, by the monitor of its subscriber's process.
    subscriptions: Dict(Monitor, Subscriber),
  )
}

type SessionState {
  SessionState(
    connection: Connection,
    /// The process ID of the registry, looked up once when the session
    /// started.
    registry: Pid,
    deadline_milliseconds: Int,
  )
}

/// The longest channel name, in bytes: PostgreSQL's NAMEDATALEN less one.
const longest_channel_bytes = 63

@external(erlang, "dream_postgres_listener_ffi", "call")
fn call_process(
  pid: Pid,
  send_request: fn(ReplyTo(reply)) -> Nil,
) -> Result(reply, Nil)

@external(erlang, "dream_postgres_listener_ffi", "reply")
fn reply(to: ReplyTo(reply), value: reply) -> Nil

/// Sends a message to the registry's process ID, tagged for its selector.
/// A send to a process that is gone does nothing.
@external(erlang, "dream_postgres_listener_ffi", "deliver")
fn send_to_registry(registry: Pid, message: ListenerProcessMessage) -> Nil

/// The message inside a message of `send_to_registry`.
@external(erlang, "dream_postgres_listener_ffi", "request_of")
fn request_of(message: Dynamic) -> ListenerProcessMessage

// Starting and stopping -------------------------------------------------------

/// Starts a listener, linked to the caller, and waits until its connection
/// connected and logged in. The registry is linked to the caller, and the
/// session to the registry. No supervisor starts the session again: a
/// crash of the session stops the listener.
///
/// ## Parameters
///
/// - `config`: the connection and the deadline of each `LISTEN`
///
/// ## Returns
///
/// - `Ok(Listener)`: the listener is connected and has no subscriber yet
/// - `Error(StartError)`: the connect, the login or the start failed. No
///   process stays.
pub fn start(config: ListenerConfig) -> Result(Listener, StartError) {
  let opened = process.new_subject()
  use started <- try(
    start_registry(config, Linked(opened)) |> map_error(ListenerNotStarted),
  )
  wait_until_opened(started, opened)
}

/// Waits for the end of the first attempt of the connection, or for the
/// end of the registry, with no timer: the connection ends its attempt by
/// its own setup deadline. After a failed attempt it also waits for the
/// end of the registry, which stops at once after its session, so no
/// process stays.
fn wait_until_opened(
  started: actor.Started(Listener),
  opened: Subject(Result(Nil, ConnectError)),
) -> Result(Listener, StartError) {
  let monitor = process.monitor(started.pid)
  let opening =
    process.new_selector()
    |> process.select_map(opened, Opened)
    |> process.select_specific_monitor(monitor, listener_down)
  case process.selector_receive_forever(opening) {
    Opened(Ok(Nil)) -> {
      process.demonitor_process(monitor)
      Ok(started.data)
    }
    Opened(Error(error)) -> {
      process.selector_receive_forever(opening)
      Error(ConnectFailed(error))
    }
    ListenerDown(reason) -> Error(ListenerNotStarted(actor.InitExited(reason)))
  }
}

fn listener_down(down: Down) -> Opening {
  ListenerDown(down.reason)
}

/// The listener as a child of a gleam_otp supervisor: a supervisor of its
/// own, with the strategy rest_for_one and two children. The first is the
/// registry, registered under `name`. The second is the session. When the
/// supervisor starts the registry again, the new registry takes the name,
/// so a handle of `from_name` stays valid. The name must come from
/// `process.new_name`, made once when the program starts.
///
/// ## Parameters
///
/// - `config`: the connection and the deadline of each `LISTEN`
/// - `name`: the name of the registry
///
/// ## Returns
///
/// A transient supervisor child: the supervisor starts it again after an
/// abnormal exit, and not after `stop`. The start does not wait for the
/// server: the connection connects after it and tries again after its
/// backoff, so a server that is down never fails the supervisor. Until the
/// connection is up, each subscriber gets `NotListening`.
///
/// A crash of the session keeps the subscriptions: each subscriber that
/// listened gets `NotListening`, the new session listens on each channel,
/// and each subscriber gets `Listening` or `ListenFailed`. A crash of the
/// registry, or a new start of the whole child, ends each subscription:
/// each subscriber gets `ListenerProcessDown` from its next call, sees the
/// `Down` of `monitor_registry`, and subscribes again.
///
/// The supervisor's shutdown stops the session, and its connection sends
/// Terminate before it stops. `stop` makes the listener's own supervisor
/// stop with the reason `shutdown`, so the process that starts this child
/// must be a supervisor, or a process that traps exits.
pub fn supervised(
  config: ListenerConfig,
  name: Name(ListenerProcessMessage),
) -> ChildSpecification(Listener) {
  supervision.supervisor(fn() { start_supervisor(config, name) })
  |> supervision.restart(Transient)
}

/// The registry is significant: its normal end after `stop` shuts the
/// supervisor down. Both children are transient: the session ends normally
/// only when the registry closed it.
fn start_supervisor(
  config: ListenerConfig,
  name: Name(ListenerProcessMessage),
) -> Result(actor.Started(Listener), actor.StartError) {
  let registry =
    supervision.worker(fn() { start_registry(config, Named(name)) })
    |> supervision.restart(Transient)
    |> supervision.significant(True)
  let session =
    supervision.worker(fn() { start_named_session(config, name) })
    |> supervision.restart(Transient)
  static_supervisor.new(RestForOne)
  |> static_supervisor.auto_shutdown(AnySignificant)
  |> static_supervisor.add(registry)
  |> static_supervisor.add(session)
  |> static_supervisor.start
  |> result.map(started_listener(_, name))
}

fn started_listener(
  started: actor.Started(static_supervisor.Supervisor),
  name: Name(ListenerProcessMessage),
) -> actor.Started(Listener) {
  actor.Started(pid: started.pid, data: from_name(name))
}

/// The listener that runs, or will run, under a name. It makes the handle
/// from the name alone, with no call to the listener, so a handle made
/// once stays valid when the supervisor starts the listener again under
/// the name.
///
/// ## Parameters
///
/// - `name`: the name of `supervised`
///
/// ## Returns
///
/// A handle of the listener. While no registry has the name, each call
/// with it gives `ListenerProcessDown`, and `stop` gives `Nil`.
pub fn from_name(name: Name(ListenerProcessMessage)) -> Listener {
  Listener(subject: process.named_subject(name))
}

/// A monitor of the listener's registry: the process that keeps the
/// subscriptions. The end of the registry ends each subscription, so a
/// subscriber that must know it monitors the registry. A crash of the
/// session alone keeps the registry, and gives no `Down`.
///
/// The caller adds the `Down` to the selector that it receives its
/// `ListenerMessage`s with: `process.select_specific_monitor(selector,
/// monitor, mapping)`, where `mapping` makes a message of the caller's own
/// type from the `Down`. After the `Down`, the caller takes the monitor off
/// the selector with `process.deselect_specific_monitor`, subscribes
/// again through a handle of `from_name`, and monitors the new registry.
///
/// ## Parameters
///
/// - `listener`: the listener
///
/// ## Returns
///
/// - `Ok(Monitor)`: a monitor of the registry that runs now, owned by the
///   caller. A registry that stops at once gives its `Down` at once.
/// - `Error(ListenerProcessDown)`: no registry runs
pub fn monitor_registry(listener: Listener) -> Result(Monitor, ListenerError) {
  subject_owner(listener.subject)
  |> result.map(process.monitor)
  |> replace_error(ListenerProcessDown)
}

/// The start of the registry does no I/O. A registry of `start` also
/// starts its session, which connects after it.
fn start_registry(
  config: ListenerConfig,
  placement: Placement,
) -> Result(actor.Started(Listener), actor.StartError) {
  let timeout = config.connection.setup_timeout_milliseconds
  actor.new_with_initialiser(timeout, initialise_registry(_, config, placement))
  |> actor.on_message(handle_registry_message)
  |> with_name(placement)
  |> actor.start
}

fn with_name(
  builder: actor.Builder(RegistryState, ListenerProcessMessage, Listener),
  placement: Placement,
) -> actor.Builder(RegistryState, ListenerProcessMessage, Listener) {
  case placement {
    Named(name) -> actor.named(builder, name)
    Linked(_starter) -> builder
  }
}

fn initialise_registry(
  subject: Subject(ListenerProcessMessage),
  config: ListenerConfig,
  placement: Placement,
) -> Result(
  actor.Initialised(RegistryState, ListenerProcessMessage, Listener),
  String,
) {
  case placement {
    Linked(starter) ->
      start_session(config, process.self())
      |> replace(registry_initialised(subject, Some(starter)))
      |> replace_error("the session did not start")
    Named(_name) -> Ok(registry_initialised(subject, None))
  }
}

fn registry_initialised(
  subject: Subject(ListenerProcessMessage),
  starter: Option(Subject(Result(Nil, ConnectError))),
) -> actor.Initialised(RegistryState, ListenerProcessMessage, Listener) {
  let state =
    RegistryState(session: None, up: False, starter:, subscriptions: dict.new())
  let selector =
    process.new_selector()
    |> process.select_record(
      atom.create("dream_postgres_listener_request"),
      1,
      request_of,
    )
    |> process.select_monitors(monitored_process_down)
  actor.initialised(state)
  |> actor.selecting(selector)
  |> actor.returning(Listener(subject:))
}

fn monitored_process_down(down: Down) -> ListenerProcessMessage {
  MonitoredProcessDown(down.monitor)
}

/// Finds the registry by its name once, so the session sends to its
/// process ID. The supervisor starts the session after the registry, so
/// the name has a process.
fn start_named_session(
  config: ListenerConfig,
  name: Name(ListenerProcessMessage),
) -> Result(actor.Started(Subject(SessionMessage)), actor.StartError) {
  process.named(name)
  |> replace_error(actor.InitFailed("the registry of the listener is gone"))
  |> try(start_session(config, _))
}

/// The start of the session does no I/O: its connection process starts
/// supervised, and connects after it.
fn start_session(
  config: ListenerConfig,
  registry: Pid,
) -> Result(actor.Started(Subject(SessionMessage)), actor.StartError) {
  let timeout = config.connection.setup_timeout_milliseconds
  actor.new_with_initialiser(timeout, initialise_session(_, config, registry))
  |> actor.on_message(handle_session_message)
  |> actor.start
}

fn initialise_session(
  subject: Subject(SessionMessage),
  config: ListenerConfig,
  registry: Pid,
) -> Result(
  actor.Initialised(SessionState, SessionMessage, Subject(SessionMessage)),
  String,
) {
  let notifications = process.new_subject()
  let events = process.new_subject()
  let connection_config =
    ConnectionConfig(
      ..config.connection,
      events: Some(sink.to(events, identity)),
      notifications: Some(sink.to(notifications, identity)),
      notices: None,
    )
  connection.supervised(connection_config).start()
  |> result.map(session_initialised(
    subject,
    config,
    registry,
    _,
    notifications,
    events,
  ))
  |> replace_error("the connection process did not start")
}

/// Tells the registry that the session started, before any event of its
/// connection, so the registry knows the session before its first report.
fn session_initialised(
  subject: Subject(SessionMessage),
  config: ListenerConfig,
  registry: Pid,
  started: actor.Started(Connection),
  notifications: Subject(Notification),
  events: Subject(ConnectionEvent),
) -> actor.Initialised(SessionState, SessionMessage, Subject(SessionMessage)) {
  send_to_registry(registry, SessionStarted(subject, process.self()))
  let state =
    SessionState(
      connection: started.data,
      registry:,
      deadline_milliseconds: config.deadline_milliseconds,
    )
  let selector =
    process.new_selector()
    |> process.select(subject)
    |> process.select_map(notifications, ConnectionNotified)
    |> process.select_map(events, ConnectionChanged)
  actor.initialised(state)
  |> actor.selecting(selector)
  |> actor.returning(subject)
}

/// Stops the listener and its connection.
///
/// ## Parameters
///
/// - `listener`: the listener to stop
///
/// ## Returns
///
/// `Nil` once the connection closed, also when the listener is gone
/// already. Its subscribers get no message. A supervised listener's
/// supervisor then stops, and is not started again.
pub fn stop(listener: Listener) -> Nil {
  call(listener, StopRequest) |> result.unwrap(Nil)
}

// Subscribing -----------------------------------------------------------------

/// Subscribes a sink to a channel. The first subscription of a channel
/// makes the session send `LISTEN`. The registry monitors the process that
/// owns the sink's subject, and ends the subscription when that process
/// stops, or when the sink's map crashes.
///
/// ## Parameters
///
/// - `listener`: the listener
/// - `channel`: the exact channel name, at most 63 bytes
/// - `subscriber`: where each notification, `NotListening`, `Listening`
///   and `ListenFailed` goes. Its map runs in the registry's process.
///
/// ## Returns
///
/// - `Ok(Subscription)`: the session is up and listens on the channel,
///   and the subscriber gets no message for it; or the session is not up,
///   and the subscriber got `NotListening`, with `Listening` or
///   `ListenFailed` after the next login (see the module documentation)
/// - `Error(ListenerError)`: the name is too long, the sink's subject has
///   no process, the `LISTEN` failed with a `ListenFailure`, or the
///   registry is gone
pub fn subscribe(
  listener: Listener,
  channel: String,
  subscriber: Sink(ListenerMessage),
) -> Result(Subscription, ListenerError) {
  use Nil <- try(check_channel(channel))
  use owner <- try(
    sink.owner(subscriber) |> replace_error(SubscriberHasNoProcess),
  )
  call(listener, SubscribeRequest(channel, subscriber, owner, _))
  |> replace_error(ListenerProcessDown)
  |> result.flatten
}

fn check_channel(channel: String) -> Result(Nil, ListenerError) {
  case byte_size(<<channel:utf8>>) > longest_channel_bytes {
    True -> Error(ChannelTooLong(channel))
    False -> Ok(Nil)
  }
}

/// Ends a subscription. When it was the last one of its channel, the
/// session sends `UNLISTEN`.
///
/// ## Parameters
///
/// - `listener`: the listener
/// - `subscription`: the subscription to end
///
/// ## Returns
///
/// - `Ok(Nil)`: the subscription is ended, also when it was ended already
/// - `Error(ListenerGone)`: the registry is gone
pub fn unsubscribe(
  listener: Listener,
  subscription: Subscription,
) -> Result(Nil, UnsubscribeError) {
  call(listener, UnsubscribeRequest(subscription, _))
  |> replace_error(ListenerGone)
}

/// Waits for the answer of the registry until it comes, or gives
/// `Error(Nil)` when the registry is gone.
fn call(
  listener: Listener,
  make: fn(ReplyTo(reply)) -> ListenerProcessMessage,
) -> Result(reply, Nil) {
  use registry <- try(subject_owner(listener.subject))
  call_process(registry, send_request(registry, make, _))
}

fn send_request(
  registry: Pid,
  make: fn(ReplyTo(reply)) -> ListenerProcessMessage,
  reply_to: ReplyTo(reply),
) -> Nil {
  send_to_registry(registry, make(reply_to))
}

// The registry ----------------------------------------------------------------

fn handle_registry_message(
  state: RegistryState,
  message: ListenerProcessMessage,
) -> actor.Next(RegistryState, ListenerProcessMessage) {
  case message {
    SubscribeRequest(channel:, subscriber:, owner:, reply: reply_to) ->
      actor.continue(add_subscriber(state, channel, subscriber, owner, reply_to))
    UnsubscribeRequest(subscription:, reply: reply_to) -> {
      let state = remove_subscriber(state, subscription.monitor)
      reply(reply_to, Nil)
      actor.continue(state)
    }
    StopRequest(reply: reply_to) -> {
      close_session(state)
      reply(reply_to, Nil)
      actor.stop()
    }
    SessionStarted(session:, pid:) ->
      actor.continue(session_started(state, session, pid))
    SessionUp -> actor.continue(session_up(state))
    SessionLost -> actor.continue(lost(RegistryState(..state, up: False)))
    SessionConnectFailed(error) -> first_connect_failed(state, error)
    NotificationReceived(notification) ->
      actor.continue(deliver(state, notification))
    MonitoredProcessDown(monitor) ->
      actor.continue(monitored_process_ended(state, monitor))
  }
}

/// Adds a subscriber, or refuses it.
fn add_subscriber(
  state: RegistryState,
  channel: String,
  subscriber_sink: Sink(ListenerMessage),
  owner: Pid,
  reply_to: ReplyTo(Result(Subscription, ListenerError)),
) -> RegistryState {
  let #(state, answer) = case admission(state, channel) {
    Admit(listening:) ->
      added(state, Subscriber(channel, subscriber_sink, listening), owner)
    Refuse(error) -> #(state, Error(SubscribeFailed(error)))
  }
  reply(reply_to, answer)
  state
}

/// A subscribe while the session is not up gets no `LISTEN`: the
/// subscriber gets `NotListening`, and the `LISTEN` of the next session
/// up gives it `Listening` or `ListenFailed`. On an up session only the
/// first subscriber of a channel needs a `LISTEN`, and a later one
/// listens when the others do.
fn admission(state: RegistryState, channel: String) -> Admission {
  case state.up, subscribers_on(state, channel) {
    False, _subscribers -> Admit(False)
    True, [] -> listen(state, channel) |> listen_admission
    True, subscribers -> Admit(any(subscribers, is_listening))
  }
}

/// A `LISTEN` that failed because the connection is not up is kept: the
/// connection process connects, and the registry asks for `LISTEN` then.
fn listen_admission(listened: Listened) -> Admission {
  case listened {
    ListenWorked -> Admit(True)
    ListenLost -> Admit(False)
    ListenNotDone(failure) -> Refuse(failure)
  }
}

fn added(
  state: RegistryState,
  subscriber: Subscriber,
  owner: Pid,
) -> #(RegistryState, Result(Subscription, ListenerError)) {
  let monitor = process.monitor(owner)
  let subscriptions = dict.insert(state.subscriptions, monitor, subscriber)
  let state = RegistryState(..state, subscriptions:)
  let state = case subscriber.listening {
    True -> state
    False -> tell(NotListening)(state, #(monitor, subscriber))
  }
  #(state, Ok(Subscription(monitor)))
}

/// Removes the subscriber of a monitor, if it is still there. When it was
/// the last one of its channel, the session sends `UNLISTEN`.
fn remove_subscriber(state: RegistryState, monitor: Monitor) -> RegistryState {
  case dict.get(state.subscriptions, monitor) {
    Ok(subscriber) -> removed(state, monitor, subscriber.channel)
    Error(Nil) -> state
  }
}

fn removed(
  state: RegistryState,
  monitor: Monitor,
  channel: String,
) -> RegistryState {
  process.demonitor_process(monitor)
  let state =
    RegistryState(
      ..state,
      subscriptions: dict.delete(state.subscriptions, monitor),
    )
  case has_subscribers(state, channel) {
    True -> state
    False -> unlisten(state, channel)
  }
}

/// Asks the session for `UNLISTEN`. Its result changes nothing: with no
/// session, or after a loss, the next session does not listen on the
/// channel, because the channel has no subscriber to listen again for, and
/// after a refusal the notifications of the channel reach no subscriber.
fn unlisten(state: RegistryState, channel: String) -> RegistryState {
  call_session(state, UnlistenRequest(channel, _)) |> result.unwrap(Nil)
  state
}

/// Asks the session for `LISTEN`. With no session, or a session that
/// stops before it answers, the connection is not up: the next session
/// listens.
fn listen(state: RegistryState, channel: String) -> Listened {
  call_session(state, ListenRequest(channel, _)) |> result.unwrap(ListenLost)
}

/// Closes the connection of the session, which then stops. With no
/// session there is nothing to close.
fn close_session(state: RegistryState) -> Nil {
  call_session(state, CloseRequest) |> result.unwrap(Nil)
}

/// Waits for the answer of the session until it comes, or gives
/// `Error(Nil)` when the registry has no session or the session is gone.
/// The session never waits for the registry, so the two never wait for
/// each other.
fn call_session(
  state: RegistryState,
  make: fn(ReplyTo(reply)) -> SessionMessage,
) -> Result(reply, Nil) {
  use session <- try(option.to_result(state.session, Nil))
  call_process(session.pid, send_to_session(session, make, _))
}

fn send_to_session(
  session: SessionLink,
  make: fn(ReplyTo(reply)) -> SessionMessage,
  reply_to: ReplyTo(reply),
) -> Nil {
  process.send(session.subject, make(reply_to))
}

// Sessions, notifications and reconnects --------------------------------------

/// A new session listens on nothing. A subscriber that still listens
/// listened on an earlier session whose end the registry did not see yet,
/// so it gets `NotListening`.
fn session_started(
  state: RegistryState,
  subject: Subject(SessionMessage),
  pid: Pid,
) -> RegistryState {
  let monitor = process.monitor(pid)
  lost(
    RegistryState(
      ..state,
      session: Some(SessionLink(subject:, pid:, monitor:)),
      up: False,
    ),
  )
}

/// Once the connection is up, the first time or again, the registry asks
/// the session for `LISTEN` on each channel and tells its subscribers the
/// result. The first one of a listener from `start` also answers its
/// starter.
fn session_up(state: RegistryState) -> RegistryState {
  let state = answer_starter(RegistryState(..state, up: True))
  list.fold(channels(state), state, listen_on_session)
}

fn answer_starter(state: RegistryState) -> RegistryState {
  case state.starter {
    Some(starter) -> process.send(starter, Ok(Nil))
    None -> Nil
  }
  RegistryState(..state, starter: None)
}

/// A failed first attempt of a listener from `start` answers its starter
/// and stops the listener. Under a supervisor the connection process tries
/// again by itself.
fn first_connect_failed(
  state: RegistryState,
  error: ConnectError,
) -> actor.Next(RegistryState, ListenerProcessMessage) {
  case state.starter {
    Some(starter) -> {
      process.send(starter, Error(error))
      close_session(state)
      actor.stop()
    }
    None -> actor.continue(state)
  }
}

/// The end of the session is a loss: the next session listens again. Any
/// other monitor is a subscriber's.
fn monitored_process_ended(
  state: RegistryState,
  monitor: Monitor,
) -> RegistryState {
  case option.map(state.session, monitor_of) == Some(monitor) {
    True -> lost(RegistryState(..state, session: None, up: False))
    False -> remove_subscriber(state, monitor)
  }
}

fn monitor_of(session: SessionLink) -> Monitor {
  session.monitor
}

fn deliver(state: RegistryState, notification: Notification) -> RegistryState {
  entries_on(state, notification.channel)
  |> fold(state, tell(NotificationArrived(notification)))
}

/// A step of a fold over subscriptions: sends the message through the
/// sink of one subscription. A sink whose map crashed is dropped: its
/// subscription ends, the same as when the subscriber's process stops.
fn tell(
  message: ListenerMessage,
) -> fn(RegistryState, #(Monitor, Subscriber)) -> RegistryState {
  fn(state: RegistryState, entry: #(Monitor, Subscriber)) {
    let #(monitor, subscriber) = entry
    sink.deliver(subscriber.sink, message)
    |> keep_subscriber(state, monitor, _)
  }
}

fn keep_subscriber(
  state: RegistryState,
  monitor: Monitor,
  delivery: Delivery,
) -> RegistryState {
  case delivery {
    Delivered -> state
    MapFailed -> remove_subscriber(state, monitor)
  }
}

/// Only the subscribers that listen get `NotListening`: one that came
/// while the connection was not up got it already.
fn lost(state: RegistryState) -> RegistryState {
  let listening = dict.to_list(state.subscriptions) |> filter(entry_listens)
  RegistryState(
    ..state,
    subscriptions: dict.map_values(state.subscriptions, not_listening),
  )
  |> fold(listening, _, tell(NotListening))
}

fn entry_listens(entry: #(Monitor, Subscriber)) -> Bool {
  is_listening(entry.1)
}

fn not_listening(_monitor: Monitor, subscriber: Subscriber) -> Subscriber {
  Subscriber(..subscriber, listening: False)
}

fn listen_on_session(state: RegistryState, channel: String) -> RegistryState {
  let listened = listen(state, channel)
  let listening = listened == ListenWorked
  let entries = entries_on(state, channel)
  let state =
    RegistryState(
      ..state,
      subscriptions: dict.map_values(
        state.subscriptions,
        fn(_monitor, subscriber) {
          listening_after(subscriber, channel, listening)
        },
      ),
    )
  case listen_message(channel, listened) {
    Some(message) -> fold(entries, state, tell(message))
    None -> state
  }
}

/// A `LISTEN` that meets a loss tells nothing: the subscribers got
/// `NotListening` already, and the next reconnect listens again.
fn listen_message(
  channel: String,
  listened: Listened,
) -> Option(ListenerMessage) {
  case listened {
    ListenWorked -> Some(Listening(channel))
    ListenLost -> None
    ListenNotDone(failure) -> Some(ListenFailed(channel, failure))
  }
}

/// The subscribers of `channel` listen when its `LISTEN` worked.
fn listening_after(
  subscriber: Subscriber,
  channel: String,
  listening: Bool,
) -> Subscriber {
  case subscriber.channel == channel {
    True -> Subscriber(..subscriber, listening:)
    False -> subscriber
  }
}

fn is_listening(subscriber: Subscriber) -> Bool {
  subscriber.listening
}

fn channels(state: RegistryState) -> List(String) {
  dict.values(state.subscriptions) |> list.map(channel_of) |> unique
}

fn channel_of(subscriber: Subscriber) -> String {
  subscriber.channel
}

fn has_subscribers(state: RegistryState, channel: String) -> Bool {
  subscribers_on(state, channel) != []
}

/// Each subscription of `channel`, with the monitor that names it.
fn entries_on(
  state: RegistryState,
  channel: String,
) -> List(#(Monitor, Subscriber)) {
  dict.to_list(state.subscriptions) |> filter(entry_on_channel(_, channel))
}

fn entry_on_channel(entry: #(Monitor, Subscriber), channel: String) -> Bool {
  on_channel(entry.1, channel)
}

fn subscribers_on(state: RegistryState, channel: String) -> List(Subscriber) {
  dict.values(state.subscriptions) |> filter(on_channel(_, channel))
}

fn on_channel(subscriber: Subscriber, channel: String) -> Bool {
  subscriber.channel == channel
}

// The session -----------------------------------------------------------------

fn handle_session_message(
  state: SessionState,
  message: SessionMessage,
) -> actor.Next(SessionState, SessionMessage) {
  case message {
    ListenRequest(channel:, reply: reply_to) -> {
      reply(reply_to, run_listen(state, channel))
      actor.continue(state)
    }
    UnlistenRequest(channel:, reply: reply_to) -> {
      run_unlisten(state, channel)
      reply(reply_to, Nil)
      actor.continue(state)
    }
    CloseRequest(reply: reply_to) -> {
      connection.stop(state.connection)
      reply(reply_to, Nil)
      actor.stop()
    }
    ConnectionNotified(notification) -> {
      send_to_registry(state.registry, NotificationReceived(notification))
      actor.continue(state)
    }
    ConnectionChanged(event) -> {
      report(state, event)
      actor.continue(state)
    }
  }
}

/// Tells the registry what changed. A failed reconnect needs nothing: the
/// connection process tries again by itself, and the registry told each
/// subscriber at the loss.
fn report(state: SessionState, event: ConnectionEvent) -> Nil {
  case event {
    Connected | Reconnected -> send_to_registry(state.registry, SessionUp)
    connection_event.ConnectFailed(error) ->
      send_to_registry(state.registry, SessionConnectFailed(error))
    ReconnectFailed(_error) -> Nil
    Disconnected(_error) -> send_to_registry(state.registry, SessionLost)
  }
}

/// Sends `UNLISTEN`. Its result changes nothing (see `unlisten`).
fn run_unlisten(state: SessionState, channel: String) -> Nil {
  case run(state, "UNLISTEN " <> quoted(channel)) {
    Ok(Nil) | Error(_loss_or_refusal) -> Nil
  }
}

fn run_listen(state: SessionState, channel: String) -> Listened {
  run(state, "LISTEN " <> quoted(channel)) |> listened
}

/// The SQL is one `LISTEN` in one Query message. Its only encode failure
/// is the zero byte: the message is far below the 2 GiB limit, because
/// the channel has at most 63 bytes. A PostgreSQL server answers it with
/// one result or one error, so `SimpleQueryFailed` and `SimpleQueryCopyRefused` come
/// only from a server that breaks the protocol.
fn listened(result: Result(Nil, SimpleQueryError)) -> Listened {
  case result {
    Ok(Nil) -> ListenWorked
    Error(SimpleQueryRequestFailed(ConnectionEnded(_)))
    | Error(SimpleQueryNotConnected(_)) -> ListenLost
    Error(SimpleQueryRequestFailed(ConnectionProcessDown)) ->
      ListenNotDone(ListenerConnectionDown)
    Error(SimpleQueryRequestFailed(DeadlinePassed(cancelled:))) ->
      ListenNotDone(ListenDeadlinePassed(cancelled))
    Error(SimpleQueryUnencodable(_zero_byte)) ->
      ListenNotDone(ChannelHasZeroByte)
    Error(SimpleQueryRefused(report:, transaction_status:)) ->
      ListenNotDone(ListenRefused(report, transaction_status))
    Error(SimpleQueryFailed(..)) | Error(SimpleQueryCopyRefused(..)) ->
      ListenNotDone(ListenAnswerUnexpected)
  }
}

fn run(state: SessionState, sql: String) -> Result(Nil, SimpleQueryError) {
  connection_simple_query.run_listener_simple_query(
    state.connection,
    sql,
    state.deadline_milliseconds,
  )
  |> replace(Nil)
}

/// The channel as a quoted identifier, so its name stays exact.
fn quoted(channel: String) -> String {
  "\"" <> replace_text(channel, "\"", "\"\"") <> "\""
}
